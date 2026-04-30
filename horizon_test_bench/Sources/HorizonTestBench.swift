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
import StarCppBridge
import StarCpp
import Semaphore

// MARK: - Top-level command

@main
struct HorizonTestBench: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "horizon_test_bench",
        abstract: "Benchmark and optimize horizon detection methods",
        subcommands: [Benchmark.self, Optimize.self, Evaluate.self, DataFormat.self, SelectTest.self],
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

// MARK: - Select-test subcommand

struct SelectTest: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "select-test",
        abstract: "Test self-scoring method selection: run 5 methods through RW, self-score, compare to reference"
    )

    @Argument(help: "Path to test data root directory")
    var dataDir: String

    @Option(name: .shortAndLong,
            help: "Max concurrent samples (default: 6)")
    var jobs: Int = 6

    @Option(name: .long, help: "Max samples to process (0 = all)")
    var maxSamples: Int = 0

    @Option(name: .long, help: "Sample every Nth image (for quick runs)")
    var stride: Int = 1

    @Option(name: .long, help: "RW working width (default 512)")
    var rwWidth: Int32 = 512

    mutating func run() async throws {
        Log.add(handler: ConsoleLogHandler(at: .warn), for: .console)

        let split = try TestDataLoader.load(from: dataDir)
        let allSamples = split.allSamples
        var selected = stride > 1
            ? Swift.stride(from: 0, to: allSamples.count, by: stride).map { allSamples[$0] }
            : allSamples
        if maxSamples > 0 { selected = Array(selected.prefix(maxSamples)) }
        let samples = selected
        print("Running select-test on \(samples.count) samples with \(jobs) concurrent jobs, RW width=\(rwWidth)")

        let semaphore = AsyncSemaphore(value: jobs)
        let collector = SelectTestCollector()
        let width = rwWidth
        let totalCount = samples.count

        await withTaskGroup(of: SelectTestResult?.self) { group in
            for (i, sample) in samples.enumerated() {
                group.addTask {
                    await semaphore.wait()
                    defer { semaphore.signal() }
                    return await SelectTest.processSample(sample, index: i, total: totalCount, rwWidth: width)
                }
            }
            for await result in group {
                if let r = result {
                    await collector.add(r)
                }
            }
        }

        await collector.printReport()
        await TaskWaiter.shared.finish()
        await logging.gremlin.finishLogging()
    }

    static func processSample(_ sample: TestSample, index: Int, total: Int, rwWidth: Int32) async -> SelectTestResult? {
        let start = CFAbsoluteTimeGetCurrent()
        FileHandle.standardError.write("  [\(index+1)/\(total)] \(sample.description)...".data(using: .utf8)!)

        guard let image = PixelatedImage(filename: sample.imagePath),
              let refMask = PixelatedImage(filename: sample.maskPath) else {
            return nil
        }

        // Compute base masks
        var baseMasks: [HorizonMethod: PixelatedImage] = [:]
        if let m = try? await OtsuRunner.run(image: image) { baseMasks[.otsu] = m }
        if let m = try? await DPRunner.run(image: image, gridSearch: true) { baseMasks[.dp] = m }
        baseMasks[.siox] = await SIOXRunner.run(image: image)
        baseMasks[.gradProfile] = GradProfileRunner.run(image: image)
        baseMasks[.texture] = TextureRunner.run(image: image)

        // Run each through RW
        let methods: [HorizonMethod] = [.otsu, .dp, .siox, .gradProfile, .texture]
        let rwMethodMap: [HorizonMethod: HorizonMethod] = [
            .otsu: .otsuThenRW, .dp: .dpThenRW, .siox: .sioxThenRW,
            .gradProfile: .gradThenRW, .texture: .textureThenRW
        ]

        struct RWResult {
            let method: HorizonMethod
            let rwMask: PixelatedImage
            let horizonY: [Int?]
            let refScore: Double
            let selfScore: Double
            let edgeScore: Double
            let baseConfidence: Double
        }

        var rwResults: [RWResult] = []
        let imgH = image.height

        for method in methods {
            guard let baseMask = baseMasks[method] else { continue }
            let baseHorizonY = BandSimulator.horizonYFromMask(baseMask)
            let baseConf = BandSimulator.horizonConfidence(baseHorizonY, imageHeight: imgH)
            let params = RWParams(maxWorkingWidth: rwWidth, brushRadius: 40)
            let rwMask = RWRunner.run(image: image, baseHorizonY: baseHorizonY, params: params)
            let rwHorizonY = BandSimulator.horizonYFromMask(rwMask)
            let refScore = MaskScorer.score(computed: rwMask, reference: refMask).combinedScore
            let selfScore = BandSimulator.selfScoreMask(rwMask, imageHeight: imgH)
            let edgeScore = BandSimulator.selfScoreWithImage(rwMask, image: image)
            rwResults.append(RWResult(
                method: rwMethodMap[method]!, rwMask: rwMask, horizonY: rwHorizonY,
                refScore: refScore, selfScore: selfScore, edgeScore: edgeScore,
                baseConfidence: baseConf
            ))
        }

        // Also compute combined+rw
        var weightedMethods: [([Int?], Double)] = []
        for method in methods {
            guard let mask = baseMasks[method] else { continue }
            let y = BandSimulator.horizonYFromMask(mask)
            let conf = BandSimulator.horizonConfidence(y, imageHeight: imgH)
            if conf > 0.05 { weightedMethods.append((y, conf)) }
        }
        if weightedMethods.isEmpty {
            for method in methods {
                guard let mask = baseMasks[method] else { continue }
                let y = BandSimulator.horizonYFromMask(mask)
                weightedMethods.append((y, 1.0))
            }
        }
        var combinedRefScore = 0.0
        if !weightedMethods.isEmpty {
            let combinedY = BandSimulator.confidenceWeightedCombine(weightedMethods)
            let params = RWParams(maxWorkingWidth: rwWidth, brushRadius: 40)
            let combinedMask = RWRunner.run(image: image, baseHorizonY: combinedY, params: params)
            combinedRefScore = MaskScorer.score(computed: combinedMask, reference: refMask).combinedScore
        }

        // Strategy 1: basic self-score
        let bestByRef = rwResults.max(by: { $0.refScore < $1.refScore })!
        let bestBySelf = rwResults.max(by: { $0.selfScore < $1.selfScore })!
        let bestByEdge = rwResults.max(by: { $0.edgeScore < $1.edgeScore })!

        // Strategy 2: consensus — pick method whose RW output is closest to median of all RW outputs
        let consensusResult: RWResult = {
            let width = rwResults[0].horizonY.count
            // Compute per-column median across all RW results
            var medianY = [Int?](repeating: nil, count: width)
            for x in 0..<width {
                let ys = rwResults.compactMap { $0.horizonY[x] }.sorted()
                if !ys.isEmpty { medianY[x] = ys[ys.count / 2] }
            }
            // For each method, compute mean absolute distance to median
            var bestDist = Double.infinity
            var bestIdx = 0
            for (i, r) in rwResults.enumerated() {
                var totalDist = 0.0
                var count = 0
                for x in 0..<width {
                    guard let my = medianY[x], let ry = r.horizonY[x] else { continue }
                    totalDist += Double(abs(my - ry))
                    count += 1
                }
                let avgDist = count > 0 ? totalDist / Double(count) : Double.infinity
                if avgDist < bestDist {
                    bestDist = avgDist
                    bestIdx = i
                }
            }
            return rwResults[bestIdx]
        }()

        // Strategy 3: base confidence — pick method with highest base (pre-RW) confidence
        let bestByBaseConf = rwResults.max(by: { $0.baseConfidence < $1.baseConfidence })!

        // Strategy 4: consensus + confidence hybrid — weight proximity to consensus by base confidence
        let hybridResult: RWResult = {
            let width = rwResults[0].horizonY.count
            var medianY = [Int?](repeating: nil, count: width)
            for x in 0..<width {
                let ys = rwResults.compactMap { $0.horizonY[x] }.sorted()
                if !ys.isEmpty { medianY[x] = ys[ys.count / 2] }
            }
            var bestScore = -Double.infinity
            var bestIdx = 0
            for (i, r) in rwResults.enumerated() {
                var totalDist = 0.0
                var count = 0
                for x in 0..<width {
                    guard let my = medianY[x], let ry = r.horizonY[x] else { continue }
                    totalDist += Double(abs(my - ry))
                    count += 1
                }
                let avgDist = count > 0 ? totalDist / Double(count) : 1000.0
                // Proximity score: 1/(1 + dist/H), weighted by base confidence
                let proximity = 1.0 / (1.0 + avgDist / Double(imgH) * 50.0)
                let score = proximity * 0.5 + r.baseConfidence * 0.5
                if score > bestScore {
                    bestScore = score
                    bestIdx = i
                }
            }
            return rwResults[bestIdx]
        }()

        let elapsed = CFAbsoluteTimeGetCurrent() - start
        FileHandle.standardError.write(" \(String(format: "%.0f", elapsed))s\n".data(using: .utf8)!)

        return SelectTestResult(
            sample: sample.description,
            sequenceName: sample.sequenceName,
            combinedRefScore: combinedRefScore,
            oracleMethod: bestByRef.method,
            oracleScore: bestByRef.refScore,
            selfSelectedMethod: bestBySelf.method,
            selfSelectedScore: bestBySelf.refScore,
            edgeSelectedMethod: bestByEdge.method,
            edgeSelectedScore: bestByEdge.refScore,
            consensusMethod: consensusResult.method,
            consensusScore: consensusResult.refScore,
            baseConfMethod: bestByBaseConf.method,
            baseConfScore: bestByBaseConf.refScore,
            hybridMethod: hybridResult.method,
            hybridScore: hybridResult.refScore
        )
    }
}

struct SelectTestResult: Sendable {
    let sample: String
    let sequenceName: String
    let combinedRefScore: Double
    let oracleMethod: HorizonMethod
    let oracleScore: Double
    let selfSelectedMethod: HorizonMethod
    let selfSelectedScore: Double
    let edgeSelectedMethod: HorizonMethod
    let edgeSelectedScore: Double
    let consensusMethod: HorizonMethod
    let consensusScore: Double
    let baseConfMethod: HorizonMethod
    let baseConfScore: Double
    let hybridMethod: HorizonMethod
    let hybridScore: Double
}

actor SelectTestCollector {
    private var results: [SelectTestResult] = []

    func add(_ result: SelectTestResult) {
        results.append(result)
    }

    func printReport() {
        let n = Double(results.count)
        guard n > 0 else { print("No results"); return }

        let avgCombined = results.map(\.combinedRefScore).reduce(0, +) / n
        let avgOracle = results.map(\.oracleScore).reduce(0, +) / n
        let avgSelfSelect = results.map(\.selfSelectedScore).reduce(0, +) / n
        let avgEdgeSelect = results.map(\.edgeSelectedScore).reduce(0, +) / n
        let avgConsensus = results.map(\.consensusScore).reduce(0, +) / n
        let avgBaseConf = results.map(\.baseConfScore).reduce(0, +) / n
        let avgHybrid = results.map(\.hybridScore).reduce(0, +) / n

        // Count correct selections
        let selfCorrect = results.filter { $0.selfSelectedMethod == $0.oracleMethod }.count
        let edgeCorrect = results.filter { $0.edgeSelectedMethod == $0.oracleMethod }.count
        let consensusCorrect = results.filter { $0.consensusMethod == $0.oracleMethod }.count
        let baseConfCorrect = results.filter { $0.baseConfMethod == $0.oracleMethod }.count
        let hybridCorrect = results.filter { $0.hybridMethod == $0.oracleMethod }.count

        print("\n" + String(repeating: "=", count: 90))
        print("SELECT-TEST RESULTS  (\(Int(n)) samples)")
        print(String(repeating: "=", count: 90))
        print()
        print("Strategy               AvgScore   vs Combined   vs Oracle   Match%")
        print(String(repeating: "-", count: 90))
        print("combined+rw            \(String(format: "%.4f", avgCombined))     —             \(String(format: "%+.4f", avgCombined - avgOracle))       —")
        print("select (basic)         \(String(format: "%.4f", avgSelfSelect))     \(String(format: "%+.4f", avgSelfSelect - avgCombined))         \(String(format: "%+.4f", avgSelfSelect - avgOracle))       \(String(format: "%.0f", Double(selfCorrect)/n*100))%")
        print("select (edge)          \(String(format: "%.4f", avgEdgeSelect))     \(String(format: "%+.4f", avgEdgeSelect - avgCombined))         \(String(format: "%+.4f", avgEdgeSelect - avgOracle))       \(String(format: "%.0f", Double(edgeCorrect)/n*100))%")
        print("select (consensus)     \(String(format: "%.4f", avgConsensus))     \(String(format: "%+.4f", avgConsensus - avgCombined))         \(String(format: "%+.4f", avgConsensus - avgOracle))       \(String(format: "%.0f", Double(consensusCorrect)/n*100))%")
        print("select (base conf)     \(String(format: "%.4f", avgBaseConf))     \(String(format: "%+.4f", avgBaseConf - avgCombined))         \(String(format: "%+.4f", avgBaseConf - avgOracle))       \(String(format: "%.0f", Double(baseConfCorrect)/n*100))%")
        print("select (hybrid)        \(String(format: "%.4f", avgHybrid))     \(String(format: "%+.4f", avgHybrid - avgCombined))         \(String(format: "%+.4f", avgHybrid - avgOracle))       \(String(format: "%.0f", Double(hybridCorrect)/n*100))%")
        print("oracle (perfect)       \(String(format: "%.4f", avgOracle))     \(String(format: "%+.4f", avgOracle - avgCombined))         —           100%")

        // Per-sequence breakdown
        var bySeq: [String: [SelectTestResult]] = [:]
        for r in results { bySeq[r.sequenceName, default: []].append(r) }

        print("\nPer-sequence breakdown:")
        print("Sequence".padding(toLength: 35, withPad: " ", startingAt: 0) +
              "N".padding(toLength: 5, withPad: " ", startingAt: 0) +
              "Combined".padding(toLength: 10, withPad: " ", startingAt: 0) +
              "Consens".padding(toLength: 10, withPad: " ", startingAt: 0) +
              "BaseConf".padding(toLength: 10, withPad: " ", startingAt: 0) +
              "Hybrid".padding(toLength: 10, withPad: " ", startingAt: 0) +
              "Oracle".padding(toLength: 10, withPad: " ", startingAt: 0))
        print(String(repeating: "-", count: 90))

        for (seq, seqResults) in bySeq.sorted(by: { $0.key < $1.key }) {
            let sn = Double(seqResults.count)
            let c = seqResults.map(\.combinedRefScore).reduce(0, +) / sn
            let con = seqResults.map(\.consensusScore).reduce(0, +) / sn
            let bc = seqResults.map(\.baseConfScore).reduce(0, +) / sn
            let h = seqResults.map(\.hybridScore).reduce(0, +) / sn
            let o = seqResults.map(\.oracleScore).reduce(0, +) / sn
            print(seq.padding(toLength: 35, withPad: " ", startingAt: 0) +
                  "\(Int(sn))".padding(toLength: 5, withPad: " ", startingAt: 0) +
                  String(format: "%.4f", c).padding(toLength: 10, withPad: " ", startingAt: 0) +
                  String(format: "%.4f", con).padding(toLength: 10, withPad: " ", startingAt: 0) +
                  String(format: "%.4f", bc).padding(toLength: 10, withPad: " ", startingAt: 0) +
                  String(format: "%.4f", h).padding(toLength: 10, withPad: " ", startingAt: 0) +
                  String(format: "%.4f", o))
        }

        // Method selection distribution
        print("\nMethod selection distribution:")
        var consDist: [HorizonMethod: Int] = [:]
        var bcDist: [HorizonMethod: Int] = [:]
        var hybDist: [HorizonMethod: Int] = [:]
        var oracleDist: [HorizonMethod: Int] = [:]
        for r in results {
            consDist[r.consensusMethod, default: 0] += 1
            bcDist[r.baseConfMethod, default: 0] += 1
            hybDist[r.hybridMethod, default: 0] += 1
            oracleDist[r.oracleMethod, default: 0] += 1
        }
        print("  Oracle:    \(oracleDist.sorted(by: { $0.value > $1.value }).map { "\($0.key.rawValue):\($0.value)" }.joined(separator: " "))")
        print("  Consensus: \(consDist.sorted(by: { $0.value > $1.value }).map { "\($0.key.rawValue):\($0.value)" }.joined(separator: " "))")
        print("  BaseConf:  \(bcDist.sorted(by: { $0.value > $1.value }).map { "\($0.key.rawValue):\($0.value)" }.joined(separator: " "))")
        print("  Hybrid:    \(hybDist.sorted(by: { $0.value > $1.value }).map { "\($0.key.rawValue):\($0.value)" }.joined(separator: " "))")

        print(String(repeating: "=", count: 90))
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
