import Foundation
import ArgumentParser
import CoreGraphics
import Cocoa
import StarCore
import logging

/*

 horizon_tester - Command line tool for testing horizon detection on a single frame.

 Runs horizon detection with multiple parameter combinations at both reduced and
 full resolution, scores each result, and writes all intermediate horizon masks
 and the final best result to an output directory for visual inspection.

 Usage:
   horizon_tester --input-image /path/to/frame.tiff --output-dir /path/to/output/

 Optional:
   --config /path/to/config.json     Load horizon detection settings from config
   --crop-amounts 30,40,50,60,70     Comma-separated crop percentages to test
   --strip-widths 0,100,200,400      Comma-separated strip widths (0 = full width)
   --shrink-factor 4                 Downscale factor for reduced-res pass
   --canny-min 50                    Canny edge detection min threshold
   --canny-max 120                   Canny edge detection max threshold
   --no-canny                        Disable Canny edge detection
   --verbose                         Enable verbose logging

*/

@main
struct HorizonTesterCli: AsyncParsableCommand {

    static let configuration = CommandConfiguration(
      commandName: "horizon_tester",
      abstract: "Test horizon detection on a single frame with multiple parameter combinations."
    )

    @Option(name: [.short, .customLong("input-image")], help: "Path to the input image file (TIFF, PNG, etc.)")
    var inputImage: String

    @Option(name: [.short, .customLong("output-dir")], help: "Directory to write output horizon mask images to")
    var outputDir: String

    @Option(name: [.short, .customLong("config")], help: "Optional path to a config.json to load settings from")
    var configFile: String?

    @Option(name: [.customLong("crop-amounts")], help: """
        Comma-separated list of crop percentage values to test.
        Each value is the percentage of the image to ignore from the top (0-100).
        Default: 30,40,50,60,70
        """)
    var cropAmountsStr: String?

    @Option(name: [.customLong("strip-widths")], help: """
        Comma-separated list of strip widths to test (in full-resolution pixels).
        0 means use full image width.
        Default: 0
        """)
    var stripWidthsStr: String?

    @Option(name: [.customLong("shrink-factor")], help: "Downscale factor for the reduced-resolution search pass. Default: 4")
    var shrinkFactor: Int?

    @Option(name: [.customLong("canny-min")], help: "Canny edge detection minimum threshold. Default: 50")
    var cannyMin: Double?

    @Option(name: [.customLong("canny-max")], help: "Canny edge detection maximum threshold. Default: 120")
    var cannyMax: Double?

    @Flag(name: [.customLong("no-canny")], help: "Disable Canny edge detection (use only Otsu)")
    var noCanny: Bool = false

    @Flag(name: [.short, .customLong("verbose")], help: "Enable verbose logging")
    var verbose: Bool = false

    // MARK: - Helpers

    private func parseCropAmounts() -> [Double] {
        if let str = cropAmountsStr {
            return str.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        }
        return [30, 40, 50, 60, 70]
    }

    private func parseStripWidths() -> [Int] {
        if let str = stripWidthsStr {
            return str.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        }
        return [0]
    }

    // MARK: - Run

    mutating func run() async throws {
        // Setup logging
        if verbose {
            Log.add(handler: ConsoleLogHandler(at: .verbose), for: .console)
        } else {
            Log.add(handler: ConsoleLogHandler(at: .info), for: .console)
        }

        // Load config if provided, otherwise use defaults
        var config = Config()
        if let configFile {
            do {
                config = try Config.read(fromJsonFilename: configFile)
                Log.i("Loaded config from \(configFile)")
            } catch {
                Log.e("Failed to load config from \(configFile): \(error)")
                Log.i("Proceeding with default config")
            }
        }

        // Apply CLI overrides
        let cropAmounts = parseCropAmounts()
        let stripWidths = parseStripWidths()
        let shrinkFactor = self.shrinkFactor ?? config.horizonSearchShrinkFactor
        let cannyMinThreshold = cannyMin ?? config.cannyMinThreshold
        let cannyMaxThreshold = cannyMax ?? config.cannyMaxThreshold
        let useCanny = !noCanny && config.useCannyForHorizonDetection
        let useL2Gradient = config.cannyUseL2Gradient

        // Load the input image
        Log.i("Loading image: \(inputImage)")
        guard let original = PixelatedImage(filename: inputImage) else {
            Log.e("Failed to load image: \(inputImage)")
            throw ExitCode.failure
        }
        Log.i("Image loaded: \(original.width) x \(original.height), \(original.bitsPerPixel) bpp")

        // Create output directory
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: outputDir) {
            try fileManager.createDirectory(atPath: outputDir, withIntermediateDirectories: true)
        }

        // Create the reduced-resolution image
        let shrunkWidth = UInt(max(1, original.width / shrinkFactor))
        let shrunkHeight = UInt(max(1, original.height / shrinkFactor))
        guard let shrunkImage = original.downScaleTo(width: shrunkWidth, height: shrunkHeight) else {
            Log.e("Failed to downscale image by factor \(shrinkFactor)")
            throw ExitCode.failure
        }
        Log.i("Shrunk image: \(shrunkImage.width) x \(shrunkImage.height) (factor \(shrinkFactor)x)")

        // Save the shrunk image for reference
        shrunkImage.writeTIFFEncoding(toFilename: "\(outputDir)/00_shrunk_input.tiff")

        // Pre-compute Canny edges for scoring
        let shrunkEdges: PixelatedImage?
        let fullResEdges: PixelatedImage?
        if useCanny {
            shrunkEdges = try? shrunkImage.cannyEdgeDetect(
              minThreshold: cannyMinThreshold,
              maxThreshold: cannyMaxThreshold,
              useL2Gradient: useL2Gradient
            )
            if let edges = shrunkEdges {
                edges.writeTIFFEncoding(toFilename: "\(outputDir)/00_shrunk_canny_edges.tiff")
            }
            fullResEdges = try? original.cannyEdgeDetect(
              minThreshold: cannyMinThreshold,
              maxThreshold: cannyMaxThreshold,
              useL2Gradient: useL2Gradient
            )
            if let edges = fullResEdges {
                edges.writeTIFFEncoding(toFilename: "\(outputDir)/00_fullres_canny_edges.tiff")
            }
        } else {
            shrunkEdges = nil
            fullResEdges = nil
        }

        // Run all combinations
        let totalCombinations = cropAmounts.count * stripWidths.count
        Log.i("Testing \(totalCombinations) parameter combinations " +
              "(\(cropAmounts.count) crop amounts x \(stripWidths.count) strip widths)")
        Log.i("Crop amounts: \(cropAmounts)")
        Log.i("Strip widths: \(stripWidths)")

        // Phase 1: Reduced resolution search
        Log.i("")
        Log.i("=== PHASE 1: Reduced Resolution (\(shrunkImage.width)x\(shrunkImage.height)) ===")
        Log.i("")

        struct TestResult {
            let cropAmount: Double
            let stripWidth: Int
            let shrunkScore: HorizonScore
            let shrunkMask: HorizonMask
        }

        var results: [TestResult] = []
        var testIndex = 0

        for cropAmount in cropAmounts {
            for fullStripWidth in stripWidths {
                testIndex += 1

                let shrunkStripWidth: Int
                if fullStripWidth == 0 {
                    shrunkStripWidth = Int(shrunkWidth)
                } else {
                    shrunkStripWidth = max(20, fullStripWidth / shrinkFactor)
                }

                let label = String(format: "crop=%05.1f_strip=%04d", cropAmount, fullStripWidth)
                Log.i("[\(testIndex)/\(totalCombinations)] Testing \(label) " +
                      "(shrunk strip=\(shrunkStripWidth))")

                guard let mask = try await shrunkImage.horizonMask(
                        at: 0,
                        bottomPercentage: cropAmount,
                        stripWidth: shrunkStripWidth,
                        useCannyEdgeDetection: useCanny,
                        cannyMinThreshold: cannyMinThreshold,
                        cannyMaxThreshold: cannyMaxThreshold,
                        useL2Gradient: useL2Gradient
                      )
                else {
                    Log.w("  -> No horizon mask produced, skipping")
                    continue
                }

                let score: HorizonScore
                if let edges = shrunkEdges {
                    score = HorizonScoring.score(horizonMask: mask, edgeImage: edges)
                } else {
                    score = HorizonScoring.score(
                      horizonMask: mask,
                      originalImage: shrunkImage,
                      cannyMinThreshold: cannyMinThreshold,
                      cannyMaxThreshold: cannyMaxThreshold,
                      useL2Gradient: useL2Gradient
                    )
                }

                Log.i("  -> \(score)")

                // Save the shrunk horizon mask
                let filename = String(
                  format: "%@/01_shrunk_%02d_%@.tiff",
                  outputDir, testIndex, label
                )
                mask.image.writeTIFFEncoding(toFilename: filename)

                results.append(TestResult(
                  cropAmount: cropAmount,
                  stripWidth: fullStripWidth,
                  shrunkScore: score,
                  shrunkMask: mask
                ))
            }
        }

        guard !results.isEmpty else {
            Log.e("No valid horizon masks produced from any parameter combination")
            throw ExitCode.failure
        }

        // Sort by score and display ranking
        let ranked = results.sorted { $0.shrunkScore.totalScore > $1.shrunkScore.totalScore }

        Log.i("")
        Log.i("=== REDUCED RESOLUTION RANKING ===")
        Log.i("")
        for (rank, result) in ranked.enumerated() {
            let marker = rank == 0 ? " <-- BEST" : ""
            Log.i(String(
              format: "  #%d: crop=%05.1f strip=%04d  score=%@%@",
              rank + 1, result.cropAmount, result.stripWidth,
              result.shrunkScore.description, marker
            ))
        }

        let best = ranked[0]

        // Phase 2: Full resolution with best parameters
        Log.i("")
        Log.i("=== PHASE 2: Full Resolution (\(original.width)x\(original.height)) ===")
        Log.i("")
        Log.i("Best parameters: crop=\(best.cropAmount), strip=\(best.stripWidth)")

        let bestStripWidth = best.stripWidth == 0 ? original.width : best.stripWidth

        guard let fullResMask = try await original.horizonMask(
                at: 0,
                bottomPercentage: best.cropAmount,
                stripWidth: bestStripWidth,
                useCannyEdgeDetection: useCanny,
                cannyMinThreshold: cannyMinThreshold,
                cannyMaxThreshold: cannyMaxThreshold,
                useL2Gradient: useL2Gradient
              )
        else {
            Log.e("Failed to create full resolution horizon mask with best parameters")
            throw ExitCode.failure
        }

        let fullResScore: HorizonScore
        if let edges = fullResEdges {
            fullResScore = HorizonScoring.score(horizonMask: fullResMask, edgeImage: edges)
        } else {
            fullResScore = HorizonScoring.score(
              horizonMask: fullResMask,
              originalImage: original,
              cannyMinThreshold: cannyMinThreshold,
              cannyMaxThreshold: cannyMaxThreshold,
              useL2Gradient: useL2Gradient
            )
        }

        Log.i("Full resolution score: \(fullResScore)")

        let scoreDiff = abs(fullResScore.totalScore - best.shrunkScore.totalScore)
        if scoreDiff > 0.2 {
            Log.w("WARNING: Full resolution score differs significantly from " +
                  "reduced resolution score (diff=\(String(format: "%.3f", scoreDiff)))")
        }

        // Save the best full-resolution mask
        fullResMask.image.writeTIFFEncoding(
          toFilename: "\(outputDir)/02_best_fullres_horizon.tiff"
        )

        if false {
            // Also run full resolution for all combinations and save them
            Log.i("")
            Log.i("=== PHASE 3: Full Resolution for All Combinations ===")
            Log.i("")

            testIndex = 0
            for result in ranked {
                testIndex += 1
                let sw = result.stripWidth == 0 ? original.width : result.stripWidth
                let label = String(format: "crop=%05.1f_strip=%04d", result.cropAmount, result.stripWidth)

                Log.i("[\(testIndex)/\(ranked.count)] Full res \(label)")

                if let mask = try await original.horizonMask(
                     at: 0,
                     bottomPercentage: result.cropAmount,
                     stripWidth: sw,
                     useCannyEdgeDetection: useCanny,
                     cannyMinThreshold: cannyMinThreshold,
                     cannyMaxThreshold: cannyMaxThreshold,
                     useL2Gradient: useL2Gradient
                   )
                {
                    let score: HorizonScore
                    if let edges = fullResEdges {
                        score = HorizonScoring.score(horizonMask: mask, edgeImage: edges)
                    } else {
                        score = HorizonScoring.score(
                          horizonMask: mask,
                          originalImage: original,
                          cannyMinThreshold: cannyMinThreshold,
                          cannyMaxThreshold: cannyMaxThreshold,
                          useL2Gradient: useL2Gradient
                        )
                    }

                    Log.i("  -> \(score)")

                    let filename = String(
                      format: "%@/03_fullres_%02d_%@.tiff",
                      outputDir, testIndex, label
                    )
                    mask.image.writeTIFFEncoding(toFilename: filename)
                } else {
                    Log.w("  -> No horizon mask produced")
                }
            }
        }
        
        // Write a summary JSON
        let summary = HorizonTestSummary(
          inputImage: inputImage,
          imageWidth: original.width,
          imageHeight: original.height,
          shrinkFactor: shrinkFactor,
          useCanny: useCanny,
          cannyMinThreshold: cannyMinThreshold,
          cannyMaxThreshold: cannyMaxThreshold,
          useL2Gradient: useL2Gradient,
          results: ranked.map { result in
              HorizonTestSummary.ResultEntry(
                cropAmount: result.cropAmount,
                stripWidth: result.stripWidth,
                smoothnessScore: result.shrunkScore.smoothnessScore,
                edgeAlignmentScore: result.shrunkScore.edgeAlignmentScore,
                coverageScore: result.shrunkScore.coverageScore,
                totalScore: result.shrunkScore.totalScore
              )
          },
          bestCropAmount: best.cropAmount,
          bestStripWidth: best.stripWidth,
          bestShrunkScore: best.shrunkScore.totalScore,
          bestFullResScore: fullResScore.totalScore
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let summaryData = try encoder.encode(summary)
        let summaryPath = "\(outputDir)/summary.json"
        try summaryData.write(to: URL(fileURLWithPath: summaryPath))

        Log.i("")
        Log.i("=== COMPLETE ===")
        Log.i("")
        Log.i("Output directory: \(outputDir)")
        Log.i("  00_shrunk_input.tiff          - Reduced resolution input")
        if useCanny {
            Log.i("  00_shrunk_canny_edges.tiff    - Canny edges (reduced res)")
            Log.i("  00_fullres_canny_edges.tiff   - Canny edges (full res)")
        }
        Log.i("  01_shrunk_NN_*.tiff           - All reduced-res horizon masks")
        Log.i("  02_best_fullres_horizon.tiff  - Best result at full resolution")
        Log.i("  03_fullres_NN_*.tiff          - All full-res horizon masks (ranked)")
        Log.i("  summary.json                  - Scores and parameters")
        Log.i("")
        Log.i("Best parameters: crop=\(best.cropAmount), strip=\(best.stripWidth)")
        Log.i("Best shrunk score:  \(best.shrunkScore)")
        Log.i("Best fullres score: \(fullResScore)")
    }
}

// MARK: - Summary JSON

struct HorizonTestSummary: Codable {
    let inputImage: String
    let imageWidth: Int
    let imageHeight: Int
    let shrinkFactor: Int
    let useCanny: Bool
    let cannyMinThreshold: Double
    let cannyMaxThreshold: Double
    let useL2Gradient: Bool
    let results: [ResultEntry]
    let bestCropAmount: Double
    let bestStripWidth: Int
    let bestShrunkScore: Double
    let bestFullResScore: Double

    struct ResultEntry: Codable {
        let cropAmount: Double
        let stripWidth: Int
        let smoothnessScore: Double
        let edgeAlignmentScore: Double
        let coverageScore: Double
        let totalScore: Double
    }
}
