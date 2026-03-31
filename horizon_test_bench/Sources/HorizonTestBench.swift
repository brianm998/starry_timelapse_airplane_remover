/*

 horizon_test_bench

 Benchmarks and optimizes horizon detection methods for nighttime timelapse images.

 Input: A directory of test data in this format:

   horizon_test_data/
     stationary/
       sequence1/
         horizon.tiff         ← single mask for all images in this sequence
         image1.tiff
         imageN.tiff
       sequence2/ ...
     moving/
       sequence1/
         original/
           image1.tiff
         horizon/
           image1.tiff        ← matching mask per frame
       sequence2/ ...

 Each horizon mask is a binary image: white (255) = sky, black (0) = ground.

 Modes:
   benchmark  — Run all methods on test data, report scores
   optimize   — Search for best parameters and method combinations
   evaluate   — Run a specific method on one image, save the result

*/

import Foundation
import ArgumentParser
import logging
import StarCore
import KHTSwift
import kht_bridge

// MARK: - Top-level command

@main
struct HorizonTestBench: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "horizon_test_bench",
        abstract: "Benchmark and optimize horizon detection methods",
        subcommands: [Benchmark.self, Optimize.self, Evaluate.self, DataFormat.self],
        defaultSubcommand: Benchmark.self
    )
}

// MARK: - Data format help subcommand

struct DataFormat: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "data-format",
        abstract: "Print the expected test data directory layout"
    )

    mutating func run() {
        print("""
        HORIZON TEST BENCH — Expected Data Format
        ==========================================

        The test data root directory must contain one or both of:

          <data-dir>/
            stationary/          (videos where the camera does not move)
            moving/              (videos where the camera moves over time)

        STATIONARY SEQUENCES
        --------------------
        Each subdirectory under stationary/ is one video sequence.
        It contains a single horizon mask that applies to every frame:

          stationary/
            sequence_name/
              horizon.tiff       ← binary horizon mask (required, exactly one)
              frame001.tiff      ← original frame image
              frame002.tiff
              ...
              frameNNN.tiff

        • The horizon mask MUST be named "horizon" with an image extension
          (.tiff, .tif, .png, .jpg, .jpeg, .bmp).
        • All other image files in the directory are treated as test frames.
        • Every frame is scored against the single horizon.tiff.

        MOVING SEQUENCES
        ----------------
        Each subdirectory under moving/ contains two parallel subdirectories
        with identically named files:

          moving/
            sequence_name/
              original/
                frame001.tiff    ← original frame image
                frame002.tiff
                ...
              horizon/
                frame001.tiff    ← horizon mask for frame001
                frame002.tiff    ← horizon mask for frame002
                ...

        • Each file in original/ must have a matching file in horizon/
          with the same name (extension may differ).
        • Frames without a matching mask are skipped with a warning.

        HORIZON MASK FORMAT
        -------------------
        • Binary image, same dimensions as the original frame.
        • White (255) = sky.
        • Black (0)   = ground.
        • Single-channel grayscale (CV_8UC1) is preferred.
          Multi-channel images are converted automatically.
        • Any standard image format is accepted:
          .tiff, .tif, .png, .jpg, .jpeg, .bmp

        EXAMPLE
        -------
          horizon_test_data/
            stationary/
              backyard_timelapse/
                horizon.tiff
                LRT_00100.tiff
                LRT_00200.tiff
                LRT_00300.tiff
              mountain_fixed_cam/
                horizon.png
                IMG_0001.tiff
                IMG_0050.tiff
            moving/
              road_trip/
                original/
                  DSC_0001.tiff
                  DSC_0002.tiff
                horizon/
                  DSC_0001.tiff
                  DSC_0002.tiff

        USAGE
        -----
          # Run all base methods on every sample:
          horizon_test_bench benchmark <data-dir> --use-all -v

          # Include base+random_walker combinations:
          horizon_test_bench benchmark <data-dir> --use-all -v --include-combined

          # Find optimal parameters (train/test split):
          horizon_test_bench optimize <data-dir> -v

          # Test a single image against all methods:
          horizon_test_bench evaluate <image> <mask> --method all

          # Control parallelism (default: physical CPU count):
          horizon_test_bench benchmark <data-dir> --use-all -j 8
        """)
    }
}

// MARK: - Benchmark subcommand

struct Benchmark: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Run all horizon detection methods on test data and report scores"
    )

    @Argument(help: "Path to test data root directory")
    var dataDir: String

    @Option(name: .long, help: "Train fraction (default 0.7)")
    var trainFraction: Double = 0.7

    @Option(name: .long, help: "Test fraction (default 0.2)")
    var testFraction: Double = 0.2

    @Option(name: .long, help: "Validation fraction (default 0.1)")
    var validationFraction: Double = 0.1

    @Option(name: .long, help: "Random seed for data split")
    var seed: UInt64 = 42

    @Flag(name: .shortAndLong, help: "Verbose output")
    var verbose: Bool = false

    @Option(name: .long, help: "Directory to save computed masks for inspection")
    var saveMasks: String? = nil

    @Flag(name: .long, help: "Also run combined methods (base + random walker)")
    var includeCombined: Bool = false

    @Flag(name: .long, help: "Run on ALL data (no train/test split)")
    var useAll: Bool = false

    @Option(name: .shortAndLong,
            help: "Max concurrent samples (default: physical CPU count)")
    var jobs: Int?

    mutating func run() async throws {
        Log.add(handler: ConsoleLogHandler(at: .warn), for: .console)

        print("Loading test data from: \(dataDir)")
        let split = try TestDataLoader.load(
            from: dataDir,
            trainFraction: trainFraction,
            testFraction: testFraction,
            validationFraction: validationFraction,
            seed: seed
        )
        print(split.summary)

        let samples = useAll ? split.allSamples : split.test
        let concurrency = jobs ?? ParallelBenchmark.defaultConcurrency

        // Create save directory if needed
        if let dir = saveMasks {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }

        let results = await ParallelBenchmark.run(
            samples: samples,
            maxConcurrency: concurrency,
            verbose: verbose,
            includeCombined: includeCombined,
            saveMasks: saveMasks
        )

        let report = BenchmarkReport(results: results)
        report.printReport()

        await TaskWaiter.shared.finish()
        await logging.gremlin.finishLogging()
    }
}

// MARK: - Optimize subcommand

struct Optimize: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Find the best method and parameters using train/test split"
    )

    @Argument(help: "Path to test data root directory")
    var dataDir: String

    @Option(name: .long, help: "Train fraction (default 0.7)")
    var trainFraction: Double = 0.7

    @Option(name: .long, help: "Test fraction (default 0.2)")
    var testFraction: Double = 0.2

    @Option(name: .long, help: "Validation fraction (default 0.1)")
    var validationFraction: Double = 0.1

    @Option(name: .long, help: "Random seed for data split")
    var seed: UInt64 = 42

    @Flag(name: .shortAndLong, help: "Verbose output")
    var verbose: Bool = false

    @Option(name: .shortAndLong,
            help: "Max concurrent samples (default: physical CPU count)")
    var jobs: Int?

    mutating func run() async throws {
        Log.add(handler: ConsoleLogHandler(at: .warn), for: .console)

        let concurrency = jobs ?? ParallelBenchmark.defaultConcurrency

        print("Loading test data from: \(dataDir)")
        let split = try TestDataLoader.load(
            from: dataDir,
            trainFraction: trainFraction,
            testFraction: testFraction,
            validationFraction: validationFraction,
            seed: seed
        )
        print(split.summary)

        let optimizer = ParameterOptimizer(verbose: verbose, maxConcurrency: concurrency)

        let result = await optimizer.optimize(
            trainSamples: split.train,
            testSamples: split.test
        )
        result.printSummary()

        // If we have validation data, evaluate on that too
        if !split.validation.isEmpty {
            print("\n--- Validation set evaluation ---")
            let valResults = await ParallelBenchmark.run(
                samples: split.validation,
                maxConcurrency: concurrency,
                verbose: verbose,
                includeCombined: true,
                saveMasks: nil
            )
            let report = BenchmarkReport(results: valResults)
            report.printReport()
        }

        await TaskWaiter.shared.finish()
        await logging.gremlin.finishLogging()
    }
}

// MARK: - Evaluate subcommand (single image)

struct Evaluate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Run a specific method on a single image and optionally save the result"
    )

    @Argument(help: "Path to input image")
    var imagePath: String

    @Argument(help: "Path to reference horizon mask (for scoring)")
    var maskPath: String

    @Option(name: .shortAndLong,
            help: "Method to run: otsu, dp, siox, rw, otsu+rw, dp+rw, siox+rw, combined+rw")
    var method: String = "all"

    @Option(name: .shortAndLong, help: "Path to save computed mask")
    var output: String? = nil

    @Option(name: .long, help: "Brush radius for RW-based methods (pixels)")
    var brushRadius: Int = 40

    @Option(name: .long, help: "DP smoothness lambda")
    var dpLambda: Double = 2.0

    @Option(name: .long, help: "DP Sobel weight")
    var dpSobel: Double = 0.6

    @Option(name: .long, help: "DP Canny weight")
    var dpCanny: Double = 0.4

    @Option(name: .long, help: "RW beta")
    var rwBeta: Double = 90.0

    @Flag(name: .shortAndLong, help: "Verbose output")
    var verbose: Bool = false

    mutating func run() async throws {
        Log.add(handler: ConsoleLogHandler(at: verbose ? .info : .warn), for: .console)

        guard let image = PixelatedImage(filename: imagePath) else {
            throw "Cannot load image: \(imagePath)"
        }
        guard let refMask = PixelatedImage(filename: maskPath) else {
            throw "Cannot load reference mask: \(maskPath)"
        }

        print("Image: \(image.width)x\(image.height)")
        print("Mask:  \(refMask.width)x\(refMask.height)")

        let methods: [String]
        if method == "all" {
            methods = ["otsu", "dp", "siox", "otsu+rw", "dp+rw", "siox+rw", "combined+rw"]
        } else {
            methods = [method]
        }

        for m in methods {
            let start = CFAbsoluteTimeGetCurrent()
            let computedMask: PixelatedImage

            switch m {
            case "otsu":
                computedMask = try await OtsuRunner.run(image: image)

            case "dp":
                let params = DPParams(
                    smoothnessLambda: dpLambda,
                    sobelWeight: dpSobel,
                    cannyWeight: dpCanny
                )
                computedMask = try await DPRunner.run(image: image, params: params, gridSearch: true)

            case "siox":
                computedMask = await SIOXRunner.run(image: image)

            case "otsu+rw":
                let base = try await OtsuRunner.run(image: image)
                let baseY = BandSimulator.horizonYFromMask(base)
                let rwParams = RWParams(beta: rwBeta, brushRadius: brushRadius)
                computedMask = RWRunner.run(image: image, baseHorizonY: baseY, params: rwParams)

            case "dp+rw":
                let params = DPParams(
                    smoothnessLambda: dpLambda,
                    sobelWeight: dpSobel,
                    cannyWeight: dpCanny
                )
                let base = try await DPRunner.run(image: image, params: params, gridSearch: true)
                let baseY = BandSimulator.horizonYFromMask(base)
                let rwParams = RWParams(beta: rwBeta, brushRadius: brushRadius)
                computedMask = RWRunner.run(image: image, baseHorizonY: baseY, params: rwParams)

            case "siox+rw":
                let base = await SIOXRunner.run(image: image)
                let baseY = BandSimulator.horizonYFromMask(base)
                let rwParams = RWParams(beta: rwBeta, brushRadius: brushRadius)
                computedMask = RWRunner.run(image: image, baseHorizonY: baseY, params: rwParams)

            case "combined+rw":
                let otsuMask = try? await OtsuRunner.run(image: image)
                let dpMask = try? await DPRunner.run(image: image, gridSearch: true)
                let sioxMask = await SIOXRunner.run(image: image)

                var arrays: [[Int?]] = []
                if let m = otsuMask { arrays.append(BandSimulator.horizonYFromMask(m)) }
                if let m = dpMask { arrays.append(BandSimulator.horizonYFromMask(m)) }
                arrays.append(BandSimulator.horizonYFromMask(sioxMask))
                let combinedY = BandSimulator.medianCombine(arrays)

                let rwParams = RWParams(beta: rwBeta, brushRadius: brushRadius)
                computedMask = RWRunner.run(image: image, baseHorizonY: combinedY, params: rwParams)

            default:
                throw "Unknown method: \(m). Use: otsu, dp, siox, otsu+rw, dp+rw, siox+rw, combined+rw"
            }

            let durationMs = (CFAbsoluteTimeGetCurrent() - start) * 1000.0
            let score = MaskScorer.score(computed: computedMask, reference: refMask)

            print("\n\(m):")
            print("  \(score)")
            print("  Time: \(Int(durationMs))ms")

            // Save mask if requested
            if let outPath = output {
                let actualPath: String
                if methods.count > 1 {
                    let ext = (outPath as NSString).pathExtension
                    let base = (outPath as NSString).deletingPathExtension
                    actualPath = "\(base)_\(m.replacingOccurrences(of: "+", with: "_")).\(ext)"
                } else {
                    actualPath = outPath
                }
                computedMask.mat.write(to: actualPath)
                print("  Saved to: \(actualPath)")
            }
        }

        await TaskWaiter.shared.finish()
        await logging.gremlin.finishLogging()
    }
}
