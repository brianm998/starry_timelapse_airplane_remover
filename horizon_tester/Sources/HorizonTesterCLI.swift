import Foundation
import ArgumentParser
import CoreGraphics
import Cocoa
import StarCore
import logging

/*

 done: 

 * add a downscaled dp horizon test, quick dirty and actually works better than full res
 * get rid of and/or otsu/dp tests
 * make [MatWrapper upscaleTo:] that smooths
 
 Horizon next steps:

 - get rid of strip width entirely (off in config for now)
 
 */



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

    @Option(name: [.customLong("dp-lambda-range")], help: """
        DP smoothness penalty range as "min,max" (cost per pixel of vertical displacement).
        Higher = smoother horizon. Default: uses config (2.0,2.0).
        Example: --dp-lambda-range 1.0,4.0
        """)
    var dpLambdaRangeStr: String?

    @Option(name: [.customLong("dp-lambda-count")], help: """
        Number of lambda values to test within the range. Default: 1 (single value).
        """)
    var dpLambdaCount: Int?

    @Option(name: [.customLong("dp-sobel-range")], help: """
        DP Sobel weight range as "min,max". Default: uses config (0.6,0.6).
        Example: --dp-sobel-range 0.4,0.8
        """)
    var dpSobelRangeStr: String?

    @Option(name: [.customLong("dp-sobel-count")], help: """
        Number of Sobel weight values to test within the range. Default: 1.
        """)
    var dpSobelCount: Int?

    @Option(name: [.customLong("dp-canny-range")], help: """
        DP Canny weight range as "min,max". Default: uses config (0.4,0.4).
        Example: --dp-canny-range 0.2,0.6
        """)
    var dpCannyRangeStr: String?

    @Option(name: [.customLong("dp-canny-count")], help: """
        Number of Canny weight values to test within the range. Default: 1.
        """)
    var dpCannyCount: Int?

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

    /// Parse a "min,max" CLI string into a [Double] range, falling back to `defaultRange`.
    private func parseRange(_ str: String?, default defaultRange: [Double]) -> [Double] {
        guard let str else { return defaultRange }
        let values = str.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        return values.count >= 2 ? [values[0], values[1]] : defaultRange
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
        let shrinkFactor = self.shrinkFactor ?? config.horizonSearchShrinkFactor
        let cannyMinThreshold = cannyMin ?? config.cannyMinThreshold
        let cannyMaxThreshold = cannyMax ?? config.cannyMaxThreshold
        let useCanny = !noCanny && config.useCannyForHorizonDetection
        let useL2Gradient = config.cannyUseL2Gradient
        let useDp = !noDp && config.useDPHorizonDetection
        // Expand each DP parameter range+count into an array of test values.
        let dpLambdaRange  = parseRange(dpLambdaRangeStr,  default: config.dpHorizonSmoothnessLambdaRange)
        let dpLambdaValues = Config.expandRange(dpLambdaRange,
                                                count: dpLambdaCount ?? config.dpHorizonSmoothnessLambdaCount)
        let dpSobelRange   = parseRange(dpSobelRangeStr,   default: config.dpHorizonSobelWeightRange)
        let dpSobelValues  = Config.expandRange(dpSobelRange,
                                                count: dpSobelCount ?? config.dpHorizonSobelWeightCount)
        let dpCannyRange   = parseRange(dpCannyRangeStr,   default: config.dpHorizonCannyWeightRange)
        let dpCannyValues  = Config.expandRange(dpCannyRange,
                                                count: dpCannyCount ?? config.dpHorizonCannyWeightCount)

        // Compute pass-1 crop amounts from bounds
        let pass1CropAmounts = HorizonCropAmounts.firstPass(bounds: cropBounds, count: count1)
        let pass1Step = HorizonCropAmounts.firstPassStep(bounds: cropBounds, count: count1)

        // Load the input image
        Log.d("Loading image: \(inputImage)")
        guard let original = PixelatedImage(filename: inputImage) else {
            Log.e("Failed to load image: \(inputImage)")
            throw ExitCode.failure
        }
        Log.d("Image loaded: \(original.width) x \(original.height), \(original.bitsPerPixel) bpp")

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
        Log.d("Shrunk image: \(shrunkImage.width) x \(shrunkImage.height) (factor \(shrinkFactor)x)")

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
                                            cropBoundaryY: cropBoundaryY,
                                            scaleFactor: shrinkFactor)
            } else {
                return HorizonScoring.score(
                  horizonMask: mask,
                  originalImage: shrunkImage,
                  cannyMinThreshold: cannyMinThreshold,
                  cannyMaxThreshold: cannyMaxThreshold,
                  useL2Gradient: useL2Gradient,
                  cropBoundaryY: cropBoundaryY,
                  scaleFactor: shrinkFactor
                )
            }
        }

        struct TestResult {
            let cropAmount: Double
            let score: HorizonScore
            let mask: HorizonMask
        }

        // ===================================================================
        // PASS 1: Coarse search at reduced resolution
        // ===================================================================
        let pass1Total = pass1CropAmounts.count
        Log.i("")
        Log.i("=== PASS 1: Coarse Search (\(shrunkImage.width)x\(shrunkImage.height)) ===")
        Log.i("Crop bounds: \(cropBounds), count1: \(count1), step: \(String(format: "%.1f", pass1Step))")
        Log.i("Crop amounts: \(pass1CropAmounts)")
        Log.i("Testing \(pass1Total) combinations")
        Log.i("")

        var pass1Results: [TestResult] = []
        var testIndex = 0

        for cropAmount in pass1CropAmounts {
            let label = String(format: "crop=%05.1f", cropAmount)
            Log.i("[\(testIndex)/\(pass1Total)] Testing \(label) " )

            guard let mask = try await shrunkImage.horizonMask(
                    at: 0,
                    bottomPercentage: cropAmount,
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

            pass1Results.append(
              TestResult(
                cropAmount: cropAmount,
                score: score,
                mask: mask
              )
            )
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
              format: "  #%d: crop=%05.1f score=%@%@",
              rank + 1, result.cropAmount,
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
        Log.i("Testing \(pass2Total) combinations")
        Log.i("")

        var pass2Results: [TestResult] = []
        testIndex = 0

        for cropAmount in pass2CropAmounts {
            testIndex += 1
            
            let label = String(format: "crop=%05.1f", cropAmount)
            Log.i("[\(testIndex)/\(pass2Total)] Testing \(label)")

            guard let mask = try await shrunkImage.horizonMask(
                    at: 0,
                    bottomPercentage: cropAmount,
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
              cropAmount: cropAmount,
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
              rank + 1, result.cropAmount,
              result.score.description, marker
            ))
        }

        let pass2Best = pass2Ranked[0]

        // ===================================================================
        // DP SHRUNK-IMAGE GRID SEARCH
        // ===================================================================
        // Run DP across all combinations of lambda × sobelWeight × cannyWeight on the
        // shrunk image, score each result, and find the best DP candidate.
        // This lets the DP search compete directly with the Otsu candidates before
        // committing to a full-resolution run.

        struct DPResult {
            let mask: HorizonMask
            let score: HorizonScore
            let lambda: Double
            let sobelW: Double
            let cannyW: Double
        }

        var dpBestShrunkResult: DPResult? = nil
        var dpShrunkAllResults: [DPResult] = []

        if useDp {
            let dpSearchTop    = pass2Best.cropAmount/100
            let dpSearchBottom = 1.0
            let dpTotal = dpLambdaValues.count * dpSobelValues.count * dpCannyValues.count

            Log.i("")
            Log.i("=== DP SHRUNK-IMAGE GRID SEARCH ===")
            Log.i("Grid: lambda×\(dpLambdaValues.count) sobel×\(dpSobelValues.count) " +
                  "canny×\(dpCannyValues.count) = \(dpTotal) combinations")
            Log.i("Search band: \(String(format:"%.0f",dpSearchTop*100))%–" +
                  "\(String(format:"%.0f",dpSearchBottom*100))% of image height")
            Log.i("")

            var dpIndex = 0
            for lambda in dpLambdaValues {
                for sobelW in dpSobelValues {
                    for cannyW in dpCannyValues {
                        dpIndex += 1
                        let label = String(format: "λ=%.2f s=%.2f c=%.2f", lambda, sobelW, cannyW)
                        Log.d("[\(dpIndex)/\(dpTotal)] DP shrunk \(label) dpSearchBottom \(dpSearchBottom)")

                        guard let dpMask = try? await shrunkImage.dpHorizonMask(
                                at: 0,
                                searchTopFraction: dpSearchTop,
                                searchBottomFraction: dpSearchBottom,
                                cannyMinThreshold: cannyMinThreshold,
                                cannyMaxThreshold: cannyMaxThreshold,
                                useL2Gradient: useL2Gradient,
                                smoothnessLambda: lambda,
                                sobelWeight: sobelW,
                                cannyWeight: cannyW
                              )
                        else {
                            Log.w("  -> DP returned nil, skipping")
                            continue
                        }

                        let score: HorizonScore
                        if let edges = shrunkEdges {
                            score = HorizonScoring.score(horizonMask: dpMask, edgeImage: edges)
                        } else {
                            score = HorizonScoring.score(
                              horizonMask: dpMask,
                              originalImage: shrunkImage,
                              cannyMinThreshold: cannyMinThreshold,
                              cannyMaxThreshold: cannyMaxThreshold,
                              useL2Gradient: useL2Gradient
                            )
                        }

                        Log.d("  -> \(score)")

                        let result = DPResult(mask: dpMask, score: score,
                                              lambda: lambda, sobelW: sobelW, cannyW: cannyW)
                        dpShrunkAllResults.append(result)

                        if let current = dpBestShrunkResult {
                            if score.totalScore > current.score.totalScore {
                                dpBestShrunkResult = result
                            }
                        } else {
                            dpBestShrunkResult = result
                        }
                    }
                }
            }

            // Write all DP shrunk results as TIFFs
            for (i, r) in dpShrunkAllResults.enumerated() {
                let filename = String(
                  format: "%@/02dp_%02d_lambda%.2f_sobel%.2f_canny%.2f.tiff",
                  outputDir, i + 1, r.lambda, r.sobelW, r.cannyW
                )
                r.mask.image.writeTIFFEncoding(toFilename: filename)
            }

            Log.i("")
            Log.i("=== DP SHRUNK RANKING ===")
            Log.i("")
            let dpRanked = dpShrunkAllResults.sorted { $0.score.totalScore > $1.score.totalScore }
            for (rank, r) in dpRanked.enumerated() {
                let marker = rank == 0 ? " <-- BEST DP" : ""
                Log.i(String(format: "  #%d: λ=%.2f s=%.2f c=%.2f  score=%@%@",
                             rank + 1, r.lambda, r.sobelW, r.cannyW, r.score.description, marker))
            }
        }

        // ===================================================================
        // FULL RESOLUTION: Generate Otsu + DP, combine, score all four
        // ===================================================================
        // We always produce:
        //   03_otsu.tiff  — Otsu+Canny at full res
        //   04_dp.tiff    — DP at full res  (when useDp and shrunk grid found a result)
        // All four are scored; the best becomes 05_best_overall_horizon.tiff.

        Log.i("")
        Log.i("=== FULL RESOLUTION (\(original.width)x\(original.height)) ===")

        // --- Otsu at full resolution ---
        Log.i("Running Otsu at full res: crop=\(pass2Best.cropAmount)")

        guard let otsuFullResMask = try await original.horizonMask(
                at: 0,
                bottomPercentage: pass2Best.cropAmount,
                useCannyEdgeDetection: useCanny,
                cannyMinThreshold: cannyMinThreshold,
                cannyMaxThreshold: cannyMaxThreshold,
                useL2Gradient: useL2Gradient
              )
        else {
            Log.e("Failed to create full resolution Otsu horizon mask")
            throw ExitCode.failure
        }

        let fullResCropBoundaryY = Int(Double(original.height) * pass2Best.cropAmount / 100.0)
        let otsuFullResScore: HorizonScore
        if let edges = fullResEdges {
            otsuFullResScore = HorizonScoring.score(horizonMask: otsuFullResMask, edgeImage: edges,
                                                    cropBoundaryY: fullResCropBoundaryY)
        } else {
            otsuFullResScore = HorizonScoring.score(
              horizonMask: otsuFullResMask,
              originalImage: original,
              cannyMinThreshold: cannyMinThreshold,
              cannyMaxThreshold: cannyMaxThreshold,
              useL2Gradient: useL2Gradient,
              cropBoundaryY: fullResCropBoundaryY
            )
        }
        Log.i("Otsu full resolution score: \(otsuFullResScore)")

        let otsuShrunkScoreDiff = abs(otsuFullResScore.totalScore - pass2Best.score.totalScore)
        if otsuShrunkScoreDiff > 0.2 {
            Log.w("WARNING: Otsu full-res score differs significantly from " +
                  "reduced-res score (diff=\(String(format: "%.3f", otsuShrunkScoreDiff)))")
        }

        otsuFullResMask.image.writeTIFFEncoding(toFilename: "\(outputDir)/03_otsu.tiff")

        // Track the current best across all four candidates
        var bestMask   = otsuFullResMask
        var fullResScore  = otsuFullResScore
        var bestMethod = "otsu"
        var dpFullResScore: HorizonScore? = nil

        // --- DP at full resolution (if enabled and shrunk grid found a winner) ---
        if useDp,
           let dpBest = dpBestShrunkResult
        {
            let dpSearchTop    = pass2Best.cropAmount / 100.0
            let dpSearchBottom = 1.0

            Log.i(String(format: "Running DP at full res: λ=%.2f s=%.2f c=%.2f",
                         dpBest.lambda, dpBest.sobelW, dpBest.cannyW))

            //if let dpFullResMask = try? await original.dpHorizonMask(
            if let ogdpFullResMask = try? await shrunkImage.dpHorizonMask(
                 at: 0,
                 searchTopFraction: dpSearchTop,
                 searchBottomFraction: dpSearchBottom,
                 cannyMinThreshold: cannyMinThreshold,
                 cannyMaxThreshold: cannyMaxThreshold,
                 useL2Gradient: useL2Gradient,
                 smoothnessLambda: dpBest.lambda,
                 sobelWeight: dpBest.sobelW,
                 cannyWeight: dpBest.cannyW
               )                 
            {
                // re-scale it back up
                let dpFullResMask = HorizonMask(
                  image: ogdpFullResMask.image
                    .downScaleTo(
                      width: UInt(original.width),
                      height: UInt(original.height)
                    )!,
                  horizonTopY: ogdpFullResMask.horizonTopY,
                  horizonBottomY: ogdpFullResMask.horizonBottomY
                )

                let dpScore: HorizonScore
                if let edges = fullResEdges {
                    dpScore = HorizonScoring.score(horizonMask: dpFullResMask, edgeImage: edges)
                } else {
                    dpScore = HorizonScoring.score(
                      horizonMask: dpFullResMask,
                      originalImage: original,
                      cannyMinThreshold: cannyMinThreshold,
                      cannyMaxThreshold: cannyMaxThreshold,
                      useL2Gradient: useL2Gradient
                    )
                }
                dpFullResScore = dpScore
                Log.i("DP full resolution score: \(dpScore)")
                dpFullResMask.image.writeTIFFEncoding(toFilename: "\(outputDir)/04_dp.tiff")

                if dpScore.totalScore > fullResScore.totalScore {
                    bestMask   = dpFullResMask
                    fullResScore  = dpScore
                    bestMethod = "dp"
                }
                Log.i("Full resolution winner: \(bestMethod) (score=\(fullResScore))")
            } else {
                Log.w("DP full resolution failed, using Otsu only")
            }
        }

        // Write the overall best result.
        Log.i("Writing \(bestMethod) result as best overall")
        bestMask.image.writeTIFFEncoding(toFilename: "\(outputDir)/05_best_overall_horizon.tiff")

        // Write summary JSON
        let allPass1Entries = pass1Ranked.map { result in
            HorizonTestSummary.ResultEntry(
              pass: 1,
              cropAmount: result.cropAmount,
              smoothnessScore: result.score.smoothnessScore,
              edgeAlignmentScore: result.score.edgeAlignmentScore,
              coverageScore: result.score.coverageScore,
              localConsistencyScore: result.score.localConsistencyScore,
              totalScore: result.score.totalScore
            )
        }
        let allPass2Entries = pass2Ranked.map { result in
            HorizonTestSummary.ResultEntry(
              pass: 2,
              cropAmount: result.cropAmount,
              smoothnessScore: result.score.smoothnessScore,
              edgeAlignmentScore: result.score.edgeAlignmentScore,
              coverageScore: result.score.coverageScore,
              localConsistencyScore: result.score.localConsistencyScore,
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
          pass2Results: allPass2Entries,
          pass2BestCrop: pass2Best.cropAmount,
          bestShrunkScore: pass2Best.score.totalScore,
          bestFullResScore: fullResScore.totalScore,
          useDp: useDp,
          dpLambdaRange: dpLambdaValues,
          dpSobelRange: dpSobelValues,
          dpCannyRange: dpCannyValues,
          dpShrunkCandidateCount: dpShrunkAllResults.count,
          dpBestShrunkScore: dpBestShrunkResult?.score.totalScore,
          dpFullResScore: dpFullResScore?.totalScore,
          overallBestMethod: bestMethod,
          overallBestScore: fullResScore.totalScore
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
        Log.i("  01_pass1_NN_*.tiff           - Pass 1 (coarse) Otsu horizon masks")
        Log.i("  02_pass2_NN_*.tiff           - Pass 2 (refined) Otsu horizon masks")
        if useDp {
            Log.i("  02dp_NN_*.tiff               - DP shrunk-image candidates")
        }
        Log.i("  03_otsu.tiff                 - Otsu result at full resolution")
        if useDp {
            Log.i("  04_dp.tiff                   - DP result at full resolution")
        }
        Log.i("  05_best_overall_horizon.tiff - Best of all four candidates")
        Log.i("  summary.json                 - Scores and parameters")
        Log.i("")
        Log.i("Pass 1 best: crop=\(pass1Best.cropAmount), " +
              "score=\(pass1Best.score)")
        Log.i("Pass 2 best: crop=\(pass2Best.cropAmount), " +
              "score=\(pass2Best.score)")
        if let dpBest = dpBestShrunkResult {
            Log.i(String(format: "DP shrunk best: λ=%.2f s=%.2f c=%.2f  score=%@",
                         dpBest.lambda, dpBest.sobelW, dpBest.cannyW, dpBest.score.description))
        }
        Log.i("Otsu full res score: \(otsuFullResScore)")
        if let dpScore = dpFullResScore {
            Log.i("DP full res score: \(dpScore)")
        }
        Log.i("Overall winner: \(bestMethod) score=\(fullResScore)")
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
    let pass2Results: [ResultEntry]
    let pass2BestCrop: Double
    let bestShrunkScore: Double
    let bestFullResScore: Double
    // DP horizon detection results
    let useDp: Bool
    let dpLambdaRange: [Double]    // actual lambda values tested (expanded from range+count)
    let dpSobelRange: [Double]     // actual sobel values tested
    let dpCannyRange: [Double]     // actual canny values tested
    let dpShrunkCandidateCount: Int
    let dpBestShrunkScore: Double?
    let dpFullResScore: Double?
    // overallBestMethod: "otsu", "dp", "otsu∧dp" (AND), or "otsu∨dp" (OR)
    let overallBestMethod: String
    let overallBestScore: Double

    struct ResultEntry: Codable {
        let pass: Int
        let cropAmount: Double
        let smoothnessScore: Double
        let edgeAlignmentScore: Double
        let coverageScore: Double
        let localConsistencyScore: Double
        let totalScore: Double
    }
}
