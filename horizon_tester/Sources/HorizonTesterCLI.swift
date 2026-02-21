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
   --crop-bounds 30,70               Min,max crop percentage bounds
   --crop-count1 5                   Number of values in first (coarse) pass
   --crop-count2 5                   Number of values in second (refined) pass
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

    @Option(name: [.customLong("crop-bounds")], help: """
        Comma-separated min,max crop percentage bounds (0-100).
        Default: 30,70
        """)
    var cropBoundsStr: String?

    @Option(name: [.customLong("crop-count1")], help: """
        Number of crop percentage values to test in the first pass.
        Default: 5
        """)
    var cropCount1: Int?

    @Option(name: [.customLong("crop-count2")], help: """
        Number of crop percentage values to test in the second refinement pass.
        Default: 5
        """)
    var cropCount2: Int?

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

    @Flag(name: [.customLong("no-dp")], help: "Disable DP horizon detection (use only Otsu)")
    var noDp: Bool = false

    @Option(name: [.customLong("dp-lambda")], help: """
        DP smoothness penalty (cost per pixel of vertical displacement).
        Higher = smoother horizon. Default: 2.0
        """)
    var dpLambda: Double?

    @Option(name: [.customLong("dp-sobel-weight")], help: """
        DP cost weight for Sobel vertical gradient. Default: 0.6
        """)
    var dpSobelWeight: Double?

    @Option(name: [.customLong("dp-canny-weight")], help: """
        DP cost weight for Canny edge presence. Default: 0.4
        """)
    var dpCannyWeight: Double?

    @Flag(name: [.short, .customLong("verbose")], help: "Enable verbose logging")
    var verbose: Bool = false

    // MARK: - Helpers

    private func parseCropBounds() -> [Double] {
        if let str = cropBoundsStr {
            let values = str.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            if values.count >= 2 { return values }
        }
        return [30, 70]
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
        let cropBounds = parseCropBounds()
        let count1 = cropCount1 ?? config.horizonSearchCropCount1
        let count2 = cropCount2 ?? config.horizonSearchCropCount2
        // Enforce minimum strip width of 20 pixels at full resolution.
        // Otsu on very narrow strips produces noisy single-pixel-width artifacts.
        let minFullResStripWidth = 20
        let rawStripWidths = parseStripWidths()
        let stripWidths = rawStripWidths.map { w in
            w == 0 ? 0 : max(minFullResStripWidth, w)
        }
        let shrinkFactor = self.shrinkFactor ?? config.horizonSearchShrinkFactor
        let cannyMinThreshold = cannyMin ?? config.cannyMinThreshold
        let cannyMaxThreshold = cannyMax ?? config.cannyMaxThreshold
        let useCanny = !noCanny && config.useCannyForHorizonDetection
        let useL2Gradient = config.cannyUseL2Gradient
        let useDp = !noDp
        let dpSmoothnessLambda = dpLambda ?? config.dpHorizonSmoothnessLambda
        let dpSobel = dpSobelWeight ?? config.dpHorizonSobelWeight
        let dpCanny = dpCannyWeight ?? config.dpHorizonCannyWeight

        // Compute pass-1 crop amounts from bounds
        let pass1CropAmounts = HorizonCropAmounts.firstPass(bounds: cropBounds, count: count1)
        let pass1Step = HorizonCropAmounts.firstPassStep(bounds: cropBounds, count: count1)

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

        // Closure to score a mask using the pre-computed edges.
        // cropBoundaryY: the pixel Y coordinate of the Otsu crop boundary on the shrunk image.
        // Pass nil to skip the crop-boundary proximity penalty (cropBoundaryScore = 1.0).
        func scoreHorizonMask(_ mask: HorizonMask, cropBoundaryY: Int? = nil) -> HorizonScore {
            if let edges = shrunkEdges {
                return HorizonScoring.score(horizonMask: mask, edgeImage: edges,
                                            cropBoundaryY: cropBoundaryY)
            } else {
                return HorizonScoring.score(
                  horizonMask: mask,
                  originalImage: shrunkImage,
                  cannyMinThreshold: cannyMinThreshold,
                  cannyMaxThreshold: cannyMaxThreshold,
                  useL2Gradient: useL2Gradient,
                  cropBoundaryY: cropBoundaryY
                )
            }
        }

        struct TestResult {
            let cropAmount: Double
            let stripWidth: Int
            let score: HorizonScore
            let mask: HorizonMask
        }

        // ===================================================================
        // PASS 1: Coarse search at reduced resolution
        // ===================================================================
        let pass1Total = pass1CropAmounts.count * stripWidths.count
        Log.i("")
        Log.i("=== PASS 1: Coarse Search (\(shrunkImage.width)x\(shrunkImage.height)) ===")
        Log.i("Crop bounds: \(cropBounds), count1: \(count1), step: \(String(format: "%.1f", pass1Step))")
        Log.i("Crop amounts: \(pass1CropAmounts)")
        Log.i("Strip widths: \(stripWidths)")
        Log.i("Testing \(pass1Total) combinations")
        Log.i("")

        var pass1Results: [TestResult] = []
        var testIndex = 0

        for cropAmount in pass1CropAmounts {
            for fullStripWidth in stripWidths {
                testIndex += 1

                let shrunkStripWidth: Int
                if fullStripWidth == 0 {
                    shrunkStripWidth = Int(shrunkWidth)
                } else {
                    shrunkStripWidth = max(20, fullStripWidth / shrinkFactor)
                }

                let label = String(format: "crop=%05.1f_strip=%04d", cropAmount, fullStripWidth)
                Log.i("[\(testIndex)/\(pass1Total)] Testing \(label) " +
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

                // crop boundary Y in shrunk-image coordinates
                let shrunkCropBoundaryY = Int(Double(shrunkImage.height) * cropAmount / 100.0)
                let score = scoreHorizonMask(mask, cropBoundaryY: shrunkCropBoundaryY)
                Log.i("  -> \(score) totalScore \(score.totalScore)")

                let filename = String(
                  format: "%@/01_pass1_%02d_%@.tiff",
                  outputDir, testIndex, label
                )
                mask.image.writeTIFFEncoding(toFilename: filename)

                pass1Results.append(TestResult(
                  cropAmount: cropAmount, stripWidth: fullStripWidth,
                  score: score, mask: mask
                ))
            }
        }

        guard !pass1Results.isEmpty else {
            Log.e("Pass 1 produced no valid horizon masks")
            throw ExitCode.failure
        }

        // Primary sort: higher total score wins.
        // Tie-break: larger cropAmount wins (more conservative sky crop; avoids
        // choosing a crop that bites into the real horizon when scores are equal).
        let pass1Ranked = pass1Results.sorted {
            if $0.score.totalScore != $1.score.totalScore {
                return $0.score.totalScore > $1.score.totalScore
            }
            return $0.cropAmount > $1.cropAmount
        }

        Log.i("")
        Log.i("=== PASS 1 RANKING ===")
        Log.i("")
        for (rank, result) in pass1Ranked.enumerated() {
            let marker = rank == 0 ? " <-- BEST" : ""
            Log.i(String(
              format: "  #%d: crop=%05.1f strip=%04d  score=%@%@",
              rank + 1, result.cropAmount, result.stripWidth,
              result.score.description, marker
            ))
        }

        let pass1Best = pass1Ranked[0]

        // ===================================================================
        // PASS 2: Refined search centered on pass-1 best crop amount
        // ===================================================================
        let pass2CropAmounts = HorizonCropAmounts.secondPass(
          bestCrop: pass1Best.cropAmount,
          firstPassStep: pass1Step,
          count: count2
        )
        let pass2Total = pass2CropAmounts.count

        Log.i("")
        Log.i("=== PASS 2: Refined Search (centered on crop=\(pass1Best.cropAmount)) ===")
        Log.i("Search area: \(String(format: "%.1f", pass2CropAmounts.first ?? 0)) to " +
              "\(String(format: "%.1f", pass2CropAmounts.last ?? 0))")
        Log.i("Crop amounts: \(pass2CropAmounts)")
        Log.i("Strip width: \(pass1Best.stripWidth) (fixed from pass 1)")
        Log.i("Testing \(pass2Total) combinations")
        Log.i("")

        var pass2Results: [TestResult] = []
        testIndex = 0

        for cropAmount in pass2CropAmounts {
            testIndex += 1
            
            let shrunkStripWidth: Int
            if pass1Best.stripWidth == 0 {
                shrunkStripWidth = Int(shrunkWidth)
            } else {
                shrunkStripWidth = max(20, pass1Best.stripWidth / shrinkFactor)
            }

            let label = String(format: "crop=%05.1f_strip=%04d", cropAmount, pass1Best.stripWidth)
            Log.i("[\(testIndex)/\(pass2Total)] Testing \(label)")

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

            // crop boundary Y in shrunk-image coordinates
            let shrunkCropBoundaryY = Int(Double(shrunkImage.height) * cropAmount / 100.0)
            let score = scoreHorizonMask(mask, cropBoundaryY: shrunkCropBoundaryY)
            Log.i("  -> \(score) total score \(score.totalScore)")

            let filename = String(
              format: "%@/02_pass2_%02d_%@.tiff",
              outputDir, testIndex, label
            )
            mask.image.writeTIFFEncoding(toFilename: filename)

            pass2Results.append(TestResult(
              cropAmount: cropAmount, stripWidth: pass1Best.stripWidth,
              score: score, mask: mask
            ))
        }

        guard !pass2Results.isEmpty else {
            Log.e("Pass 2 produced no valid horizon masks")
            throw ExitCode.failure
        }

        // Same tie-breaking as pass 1: prefer larger cropAmount on equal scores.
        let pass2Ranked = pass2Results.sorted {
            if $0.score.totalScore != $1.score.totalScore {
                return $0.score.totalScore > $1.score.totalScore
            }
            return $0.cropAmount > $1.cropAmount
        }

        Log.i("")
        Log.i("=== PASS 2 RANKING ===")
        Log.i("")
        for (rank, result) in pass2Ranked.enumerated() {
            let marker = rank == 0 ? " <-- BEST" : ""
            Log.i(String(
              format: "  #%d: crop=%05.1f strip=%04d  score=%@%@",
              rank + 1, result.cropAmount, result.stripWidth,
              result.score.description, marker
            ))
        }

        let pass2Best = pass2Ranked[0]

        // ===================================================================
        // FULL RESOLUTION: Apply pass-2 best parameters
        // ===================================================================
        Log.i("")
        Log.i("=== FULL RESOLUTION (\(original.width)x\(original.height)) ===")
        Log.i("Final parameters: crop=\(pass2Best.cropAmount), strip=\(pass2Best.stripWidth)")
        Log.i("")

        let bestStripWidth = pass2Best.stripWidth == 0 ? original.width : pass2Best.stripWidth

        guard let fullResMask = try await original.horizonMask(
                at: 0,
                bottomPercentage: pass2Best.cropAmount,
                stripWidth: bestStripWidth,
                useCannyEdgeDetection: useCanny,
                cannyMinThreshold: cannyMinThreshold,
                cannyMaxThreshold: cannyMaxThreshold,
                useL2Gradient: useL2Gradient
              )
        else {
            Log.e("Failed to create full resolution horizon mask")
            throw ExitCode.failure
        }

        // crop boundary Y in full-resolution coordinates
        let fullResCropBoundaryY = Int(Double(original.height) * pass2Best.cropAmount / 100.0)
        let fullResScore: HorizonScore
        if let edges = fullResEdges {
            fullResScore = HorizonScoring.score(horizonMask: fullResMask, edgeImage: edges,
                                                cropBoundaryY: fullResCropBoundaryY)
        } else {
            fullResScore = HorizonScoring.score(
              horizonMask: fullResMask,
              originalImage: original,
              cannyMinThreshold: cannyMinThreshold,
              cannyMaxThreshold: cannyMaxThreshold,
              useL2Gradient: useL2Gradient,
              cropBoundaryY: fullResCropBoundaryY
            )
        }

        Log.i("Full resolution score: \(fullResScore)")

        let scoreDiff = abs(fullResScore.totalScore - pass2Best.score.totalScore)
        if scoreDiff > 0.2 {
            Log.w("WARNING: Full resolution score differs significantly from " +
                  "reduced resolution score (diff=\(String(format: "%.3f", scoreDiff)))")
        }

        fullResMask.image.writeTIFFEncoding(
          toFilename: "\(outputDir)/03_best_fullres_otsu_horizon.tiff"
        )

        // ===================================================================
        // DP HORIZON DETECTION: Run in parallel and compare
        // ===================================================================
        var dpFullResScore: HorizonScore? = nil
        var dpWins = false

        if useDp {
            Log.i("")
            Log.i("=== DP HORIZON DETECTION ===")
            Log.i("Parameters: lambda=\(dpSmoothnessLambda), " +
                  "sobelWeight=\(dpSobel), cannyWeight=\(dpCanny)")
            Log.i("Search region: crop=\(pass2Best.cropAmount)% from top")
            Log.i("")

            do {
                if let dpMask = try await original.dpHorizonMask(
                     at: 0,
                     //bottomPercentage: pass2Best.cropAmount,
                     cannyMinThreshold: cannyMinThreshold,
                     cannyMaxThreshold: cannyMaxThreshold,
                     useL2Gradient: useL2Gradient,
                     smoothnessLambda: dpSmoothnessLambda,
                     sobelWeight: dpSobel,
                     cannyWeight: dpCanny
                   )
                {
                    let dpScore: HorizonScore
                    if let edges = fullResEdges {
                        dpScore = HorizonScoring.score(horizonMask: dpMask, edgeImage: edges)
                    } else {
                        dpScore = HorizonScoring.score(
                          horizonMask: dpMask,
                          originalImage: original,
                          cannyMinThreshold: cannyMinThreshold,
                          cannyMaxThreshold: cannyMaxThreshold,
                          useL2Gradient: useL2Gradient
                        )
                    }

                    dpFullResScore = dpScore

                    dpMask.image.writeTIFFEncoding(
                      toFilename: "\(outputDir)/04_dp_horizon.tiff"
                    )

                    Log.i("DP horizon score: \(dpScore)")

                    if dpScore.totalScore > fullResScore.totalScore {
                        Log.i("DP WINS: \(String(format: "%.3f", dpScore.totalScore)) > " +
                              "Otsu \(String(format: "%.3f", fullResScore.totalScore))")
                        dpWins = true
                    } else {
                        Log.i("Otsu WINS: \(String(format: "%.3f", fullResScore.totalScore)) > " +
                              "DP \(String(format: "%.3f", dpScore.totalScore))")
                    }
                } else {
                    Log.w("DP horizon detection returned nil")
                }
            } catch {
                Log.w("DP horizon detection failed: \(error)")
            }
        }

        // Write the overall best result.
        // Use FileManager to copy the winning mask file instead of regenerating it.
        let bestSourceFile: String
        if dpWins {
            Log.i("Writing DP result as best overall")
            bestSourceFile = "\(outputDir)/04_dp_horizon.tiff"
        } else {
            Log.i("Writing Otsu result as best overall")
            bestSourceFile = "\(outputDir)/03_best_fullres_otsu_horizon.tiff"
        }
        let bestDestFile = "\(outputDir)/05_best_overall_horizon.tiff"
        try? fileManager.removeItem(atPath: bestDestFile)
        try? fileManager.copyItem(atPath: bestSourceFile, toPath: bestDestFile)

        // Write summary JSON
        let allPass1Entries = pass1Ranked.map { result in
            HorizonTestSummary.ResultEntry(
              pass: 1,
              cropAmount: result.cropAmount,
              stripWidth: result.stripWidth,
              smoothnessScore: result.score.smoothnessScore,
              edgeAlignmentScore: result.score.edgeAlignmentScore,
              coverageScore: result.score.coverageScore,
              localConsistencyScore: result.score.localConsistencyScore,
              flatnessScore: result.score.flatnessScore,
              totalScore: result.score.totalScore
            )
        }
        let allPass2Entries = pass2Ranked.map { result in
            HorizonTestSummary.ResultEntry(
              pass: 2,
              cropAmount: result.cropAmount,
              stripWidth: result.stripWidth,
              smoothnessScore: result.score.smoothnessScore,
              edgeAlignmentScore: result.score.edgeAlignmentScore,
              coverageScore: result.score.coverageScore,
              localConsistencyScore: result.score.localConsistencyScore,
              flatnessScore: result.score.flatnessScore,
              totalScore: result.score.totalScore
            )
        }

        let summary = HorizonTestSummary(
          inputImage: inputImage,
          imageWidth: original.width,
          imageHeight: original.height,
          shrinkFactor: shrinkFactor,
          useCanny: useCanny,
          cannyMinThreshold: cannyMinThreshold,
          cannyMaxThreshold: cannyMaxThreshold,
          useL2Gradient: useL2Gradient,
          cropBounds: cropBounds,
          cropCount1: count1,
          cropCount2: count2,
          pass1Step: pass1Step,
          pass1Results: allPass1Entries,
          pass1BestCrop: pass1Best.cropAmount,
          pass1BestStrip: pass1Best.stripWidth,
          pass2Results: allPass2Entries,
          pass2BestCrop: pass2Best.cropAmount,
          pass2BestStrip: pass2Best.stripWidth,
          bestShrunkScore: pass2Best.score.totalScore,
          bestOtsuFullResScore: fullResScore.totalScore,
          useDp: useDp,
          dpSmoothnessLambda: dpSmoothnessLambda,
          dpSobelWeight: dpSobel,
          dpCannyWeight: dpCanny,
          dpFullResScore: dpFullResScore?.totalScore,
          dpWins: dpWins,
          overallBestMethod: dpWins ? "dp" : "otsu",
          overallBestScore: dpWins ? (dpFullResScore?.totalScore ?? fullResScore.totalScore) : fullResScore.totalScore
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
        Log.i("  00_shrunk_input.tiff              - Reduced resolution input")
        if useCanny {
            Log.i("  00_shrunk_canny_edges.tiff        - Canny edges (reduced res)")
            Log.i("  00_fullres_canny_edges.tiff       - Canny edges (full res)")
        }
        Log.i("  01_pass1_NN_*.tiff                - Pass 1 (coarse) horizon masks")
        Log.i("  02_pass2_NN_*.tiff                - Pass 2 (refined) horizon masks")
        Log.i("  03_best_fullres_otsu_horizon.tiff - Best Otsu result at full resolution")
        if useDp {
            Log.i("  04_dp_horizon.tiff                - DP horizon detection result")
        }
        Log.i("  05_best_overall_horizon.tiff      - Overall best horizon mask")
        Log.i("  summary.json                      - Scores and parameters")
        Log.i("")
        Log.i("Pass 1 best: crop=\(pass1Best.cropAmount), strip=\(pass1Best.stripWidth), " +
              "score=\(pass1Best.score)")
        Log.i("Pass 2 best: crop=\(pass2Best.cropAmount), strip=\(pass2Best.stripWidth), " +
              "score=\(pass2Best.score)")
        Log.i("Otsu full res score: \(fullResScore)")
        if let dpScore = dpFullResScore {
            Log.i("DP full res score: \(dpScore)")
        }
        Log.i("Overall winner: \(dpWins ? "DP" : "Otsu")")
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
    let cropBounds: [Double]
    let cropCount1: Int
    let cropCount2: Int
    let pass1Step: Double
    let pass1Results: [ResultEntry]
    let pass1BestCrop: Double
    let pass1BestStrip: Int
    let pass2Results: [ResultEntry]
    let pass2BestCrop: Double
    let pass2BestStrip: Int
    let bestShrunkScore: Double
    let bestOtsuFullResScore: Double
    // DP horizon detection results
    let useDp: Bool
    let dpSmoothnessLambda: Double
    let dpSobelWeight: Double
    let dpCannyWeight: Double
    let dpFullResScore: Double?
    let dpWins: Bool
    let overallBestMethod: String
    let overallBestScore: Double

    struct ResultEntry: Codable {
        let pass: Int
        let cropAmount: Double
        let stripWidth: Int
        let smoothnessScore: Double
        let edgeAlignmentScore: Double
        let coverageScore: Double
        let localConsistencyScore: Double
        let flatnessScore: Double
        let totalScore: Double
    }
}
