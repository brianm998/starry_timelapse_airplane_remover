import Foundation
import logging

/// Scores a horizon detection result to allow comparison between parameter combinations.
/// Higher total score means better detected horizon.
public struct HorizonScore: Sendable, CustomStringConvertible {
    /// How smooth the horizon line is (low derivative variance = high score).
    /// A real horizon changes gradually across the image.
    public let smoothnessScore: Double

    /// What fraction of the detected horizon boundary aligns with actual edges
    /// in the source image (via Canny edge detection).
    public let edgeAlignmentScore: Double

    /// Penalizes degenerate results where the mask is nearly all-sky or all-ground.
    /// 1.0 = reasonable ground/sky ratio, 0.0 = degenerate.
    public let coverageScore: Double

    /// Penalizes horizon lines with isolated spike columns that deviate drastically
    /// from their local neighborhood. 1.0 = no spikes, 0.0 = many spikes.
    /// This catches single-pixel-width vertical artifacts that the global smoothness
    /// score may miss (since stddev averages out isolated spikes).
    public let localConsistencyScore: Double

    /// Penalizes horizon lines that are flat (constant Y) across large portions
    /// of the image. A flat horizon typically means the crop amount was set too
    /// aggressively, cropping the actual horizon and leaving only the straight
    /// crop boundary. 1.0 = no significant flat segments, 0.0 = entirely flat.
    public let flatnessScore: Double

    /// Combined weighted score. Higher is better.
    public var totalScore: Double {
        // Smoothness is a strong signal - a jerky horizon is almost certainly wrong.
        // Edge alignment confirms the horizon sits on a real intensity boundary.
        // Coverage prevents degenerate all-sky or all-ground results.
        // Local consistency catches isolated spike artifacts from too-narrow strips.
        // Flatness catches degenerate results from over-cropping.
        let smoothnessWeight = 0.25
        let edgeAlignmentWeight = 0.25
        let coverageWeight = 0.10
        let localConsistencyWeight = 0.20
        let flatnessWeight = 0.20
        return smoothnessScore * smoothnessWeight +
               edgeAlignmentScore * edgeAlignmentWeight +
               coverageScore * coverageWeight +
               localConsistencyScore * localConsistencyWeight +
               flatnessScore * flatnessWeight
    }

    public var description: String {
        String(format: "HorizonScore(total=%.3f, smooth=%.3f, edge=%.3f, coverage=%.3f, consist=%.3f, flat=%.3f)",
               totalScore, smoothnessScore, edgeAlignmentScore, coverageScore,
               localConsistencyScore, flatnessScore)
    }
}

/// The result of a single parameter combination trial during adaptive horizon search.
struct HorizonSearchResult: Sendable {
    let cropAmount: Double      // the bottomPercentage used
    let stripWidth: Int         // the stripWidth used (in full-resolution pixels)
    let horizonMask: HorizonMask
    let score: HorizonScore
}

/// Computes evenly spaced crop amount arrays from bounds and step counts.
public enum HorizonCropAmounts {

    /// Generate the first-pass crop amount array from [min, max] bounds and a step count.
    /// Returns evenly spaced values including both endpoints.
    /// e.g. bounds=[30,70], count=5 -> [30, 40, 50, 60, 70]
    public static func firstPass(bounds: [Double], count: Int) -> [Double] {
        guard bounds.count >= 2 else { return [50] }
        let lo = bounds[0]
        let hi = bounds[1]
        let n = max(2, count)
        let step = (hi - lo) / Double(n - 1)
        return (0..<n).map { lo + Double($0) * step }
    }

    /// Compute the step size used in the first pass.
    public static func firstPassStep(bounds: [Double], count: Int) -> Double {
        guard bounds.count >= 2 else { return 10 }
        let lo = bounds[0]
        let hi = bounds[1]
        let n = max(2, count)
        return (hi - lo) / Double(n - 1)
    }

    /// Generate the second-pass crop amount array centered on the first-pass best value.
    /// The search area spans one first-pass step in each direction (2 * step total),
    /// divided into `count` evenly spaced values.
    /// e.g. bestCrop=50, step1=10, count=5 -> [40, 45, 50, 55, 60]
    public static func secondPass(
      bestCrop: Double,
      firstPassStep step1: Double,
      count: Int
    ) -> [Double] {
        let halfRange = step1 // one step in each direction
        let lo = max(0, bestCrop - halfRange)
        let hi = min(100, bestCrop + halfRange)
        let n = max(2, count)
        let step = (hi - lo) / Double(n - 1)
        return (0..<n).map { lo + Double($0) * step }
    }
}

/// Tracks the best-known parameters from previous frames to narrow future searches.
public actor AdaptiveHorizonState {
    private var lastBestCropAmount: Double?
    private var lastBestStripWidth: Int?
    private var lastFirstPassStep: Double?
    private var frameCount: Int = 0

    public init() {}

    /// Record the best parameters found for a frame.
    func recordBest(cropAmount: Double, stripWidth: Int, firstPassStep: Double) {
        lastBestCropAmount = cropAmount
        lastBestStripWidth = stripWidth
        lastFirstPassStep = firstPassStep
        frameCount += 1
    }

    /// Get narrowed first-pass crop bounds for subsequent frames.
    /// After the first frame, we center the search around the previous best
    /// and narrow the range.
    func narrowedCropBounds(
      defaults: [Double],
      narrowingRange: Double
    ) -> [Double] {
        guard let lastBest = lastBestCropAmount, frameCount > 0 else {
            return defaults
        }

        let lo = max(0, lastBest - narrowingRange)
        let hi = min(100, lastBest + narrowingRange)
        return [lo, hi]
    }

    /// Get narrowed strip widths for subsequent frames.
    /// After the first frame, just reuse the best strip width found.
    func narrowedStripWidths(defaults: [Int]) -> [Int] {
        guard let lastBest = lastBestStripWidth, frameCount > 0 else {
            return defaults
        }
        // After we've found a good strip width, stick with it
        // (strip width tends to be stable across a sequence)
        return [lastBest]
    }

    /// Whether this is the first frame (no prior data).
    var isFirstFrame: Bool { frameCount == 0 }
}

/// Computes horizon scores for a binary horizon mask image.
public enum HorizonScoring {

    /// Extract the horizon Y coordinate per column from a binary mask.
    /// The horizon Y is defined as the topmost black (ground) pixel in each column.
    /// Returns nil for columns that are all-white (all sky) or all-black (all ground).
    public static func extractHorizonYPerColumn(from mask: PixelatedImage) -> [Int?] {
        let w = mask.width
        let h = mask.height
        var horizonY = [Int?](repeating: nil, count: w)

        // The mask is a binary image: white (255) = sky, black (0) = ground.
        // For each column, find the first black pixel from the top.
        for x in 0..<w {
            for y in 0..<h {
                let intensity = mask.intensity(atX: x, andY: y)
                if intensity == 0 {
                    // Found ground - this is the horizon Y for this column
                    horizonY[x] = y
                    break
                }
            }
        }

        return horizonY
    }

    /// Compute the smoothness score from per-column horizon Y values.
    /// Score is 1.0 / (1.0 + stddev(derivative)).
    /// Columns with nil values are skipped in the derivative computation.
    public static func smoothnessScore(horizonY: [Int?]) -> Double {
        // Compute column-to-column differences where both neighbors are non-nil
        var diffs: [Double] = []
        for i in 1..<horizonY.count {
            if let prev = horizonY[i - 1], let curr = horizonY[i] {
                diffs.append(Double(curr - prev))
            }
        }

        guard diffs.count > 1 else {
            // Not enough data points - return neutral score
            return 0.5
        }

        let mean = diffs.reduce(0, +) / Double(diffs.count)
        let variance = diffs.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(diffs.count)
        let stddev = sqrt(variance)

        // Score: lower stddev = smoother = higher score
        // A perfectly smooth horizon has stddev=0 -> score=1.0
        // stddev of 10 pixels -> score ~= 0.09
        return 1.0 / (1.0 + stddev)
    }

    /// Compute edge alignment score: what fraction of horizon pixels coincide with
    /// Canny edges in the source image.
    /// `horizonY` is the per-column horizon Y from the mask.
    /// `edgeImage` is the Canny edge detection result (white=edge, black=no edge).
    /// `tolerance` is how many pixels away from the horizon Y to search for an edge.
    public static func edgeAlignmentScore(
      horizonY: [Int?],
      edgeImage: PixelatedImage,
      tolerance: Int = 3
    ) -> Double {
        var alignedCount = 0
        var totalCount = 0

        for (x, yOpt) in horizonY.enumerated() {
            guard let y = yOpt else { continue }
            guard x < edgeImage.width else { continue }
            totalCount += 1

            // Check if there's an edge within +/- tolerance pixels of the horizon
            let yMin = max(0, y - tolerance)
            let yMax = min(edgeImage.height - 1, y + tolerance)
            guard yMin <= yMax else { continue }

            for checkY in yMin...yMax {
                let intensity = edgeImage.intensity(atX: x, andY: checkY)
                if intensity > 128 {
                    // Found an edge near the horizon
                    alignedCount += 1
                    break
                }
            }
        }

        guard totalCount > 0 else { return 0.0 }
        return Double(alignedCount) / Double(totalCount)
    }

    /// Compute local consistency score: penalize horizon lines with isolated spike
    /// columns that deviate drastically from their local neighborhood.
    ///
    /// For each column with a defined horizon Y, we compare it to the median of a
    /// local window (±windowRadius columns). If the column deviates by more than
    /// `spikeThreshold` pixels from the local median, it's counted as a spike.
    /// The score is `1.0 - fractionOfSpikes`.
    ///
    /// This catches the single-pixel-width vertical artifacts that result from
    /// Otsu thresholding on very narrow strips, where individual columns can jump
    /// drastically while the overall stddev remains low (because the spikes are
    /// isolated among many smooth columns).
    public static func localConsistencyScore(
      horizonY: [Int?],
      windowRadius: Int = 5,
      spikeThreshold: Double = 8.0
    ) -> Double {
        let count = horizonY.count
        guard count > 0 else { return 0.0 }

        var spikeCount = 0
        var definedCount = 0

        for i in 0..<count {
            guard let y = horizonY[i] else { continue }
            definedCount += 1

            // Collect defined values in the local window
            let lo = max(0, i - windowRadius)
            let hi = min(count - 1, i + windowRadius)
            var localValues: [Int] = []
            for j in lo...hi {
                if let v = horizonY[j] { localValues.append(v) }
            }

            guard localValues.count >= 3 else { continue }

            // Compute median of local window
            localValues.sort()
            let median: Double
            let n = localValues.count
            if n % 2 == 0 {
                median = Double(localValues[n / 2 - 1] + localValues[n / 2]) / 2.0
            } else {
                median = Double(localValues[n / 2])
            }

            // Count as spike if deviation exceeds threshold
            if abs(Double(y) - median) > spikeThreshold {
                spikeCount += 1
            }
        }

        guard definedCount > 0 else { return 0.0 }
        let fractionSpikes = Double(spikeCount) / Double(definedCount)

        // Score: no spikes = 1.0, all spikes = 0.0.
        // Use a slightly aggressive curve so even a small fraction of spikes
        // gets penalized noticeably: score = (1 - fractionSpikes)^2
        let raw = 1.0 - fractionSpikes
        return raw * raw
    }

    /// Compute flatness score: penalize horizon lines that are flat (constant Y)
    /// across large portions of the image.
    ///
    /// Walks along the defined horizon Y values and finds runs of consecutive
    /// columns at the same Y value. Short flat segments (≤ `minRunLength` columns)
    /// are normal and ignored. Longer flat segments indicate the horizon was
    /// cropped away, leaving only the straight crop boundary.
    ///
    /// The score is based on what fraction of defined columns are part of
    /// flat runs exceeding the minimum length:
    /// - 0% flat → score 1.0
    /// - 33%+ flat → score drops sharply
    /// - 100% flat → score ~0.0
    ///
    /// `minRunLength` is the minimum number of consecutive same-Y columns
    /// before a run is considered "flat". Default 20 pixels.
    public static func flatnessScore(
      horizonY: [Int?],
      minRunLength: Int = 20
    ) -> Double {
        let count = horizonY.count
        guard count > 0 else { return 1.0 }

        // Walk through defined columns, tracking runs of identical Y values
        var flatPixelCount = 0
        var definedCount = 0
        var currentRunY: Int? = nil
        var currentRunLength = 0

        for i in 0..<count {
            guard let y = horizonY[i] else {
                // End of any current run when we hit an undefined column
                if currentRunLength > minRunLength {
                    flatPixelCount += currentRunLength
                }
                currentRunY = nil
                currentRunLength = 0
                continue
            }
            definedCount += 1

            if let runY = currentRunY, y == runY {
                // Continue the current run
                currentRunLength += 1
            } else {
                // End previous run if it was long enough
                if currentRunLength > minRunLength {
                    flatPixelCount += currentRunLength
                }
                // Start a new run
                currentRunY = y
                currentRunLength = 1
            }
        }
        // Don't forget the last run
        if currentRunLength > minRunLength {
            flatPixelCount += currentRunLength
        }

        guard definedCount > 0 else { return 1.0 }

        let flatFraction = Double(flatPixelCount) / Double(definedCount)

        // Score: no flat segments = 1.0, fully flat = 0.0.
        // Use a curve that penalizes aggressively once flatness exceeds ~20%:
        //   score = max(0, 1 - 2 * flatFraction)^1.5
        // This means:
        //   0% flat   → 1.0
        //   10% flat  → ~0.72
        //   25% flat  → ~0.35
        //   33% flat  → ~0.19
        //   50%+ flat → 0.0
        let raw = max(0.0, 1.0 - 2.0 * flatFraction)
        return pow(raw, 1.5)
    }

    /// Compute coverage score: penalize degenerate results that are nearly all-sky
    /// or all-ground.
    /// `horizonY` is the per-column horizon Y from the mask.
    /// `imageHeight` is the total height of the mask image.
    public static func coverageScore(horizonY: [Int?], imageHeight: Int) -> Double {
        let definedColumns = horizonY.compactMap { $0 }
        guard !definedColumns.isEmpty else {
            // No horizon detected at all - worst possible score
            return 0.0
        }

        let fractionDefined = Double(definedColumns.count) / Double(horizonY.count)

        // Average position of the horizon as a fraction of image height
        let avgY = Double(definedColumns.reduce(0, +)) / Double(definedColumns.count)
        let relativePosition = avgY / Double(imageHeight)

        // Penalize if horizon is too close to top (< 5%) or bottom (> 95%)
        // Also penalize if too few columns have a defined horizon
        let positionScore: Double
        if relativePosition < 0.05 || relativePosition > 0.95 {
            positionScore = 0.1
        } else {
            positionScore = 1.0
        }

        return positionScore * fractionDefined
    }

    /// Compute a full HorizonScore for a horizon mask, given the original image
    /// for edge alignment checks.
    public static func score(
      horizonMask: HorizonMask,
      originalImage: PixelatedImage,
      cannyMinThreshold: Double,
      cannyMaxThreshold: Double,
      useL2Gradient: Bool
    ) -> HorizonScore {
        let mask = horizonMask.image
        let horizonY = extractHorizonYPerColumn(from: mask)
        let smoothness = smoothnessScore(horizonY: horizonY)

        // Compute edge alignment using Canny on the original
        let edgeAlignment: Double
        if let edges = try? originalImage.cannyEdgeDetect(
             minThreshold: cannyMinThreshold,
             maxThreshold: cannyMaxThreshold,
             useL2Gradient: useL2Gradient
           )
        {
            edgeAlignment = edgeAlignmentScore(
              horizonY: horizonY,
              edgeImage: edges,
              tolerance: 3
            )
        } else {
            edgeAlignment = 0.5 // neutral if Canny fails
        }

        let coverage = coverageScore(horizonY: horizonY, imageHeight: mask.height)
        let consistency = localConsistencyScore(horizonY: horizonY)
        let flatness = flatnessScore(horizonY: horizonY)

        return HorizonScore(
          smoothnessScore: smoothness,
          edgeAlignmentScore: edgeAlignment,
          coverageScore: coverage,
          localConsistencyScore: consistency,
          flatnessScore: flatness
        )
    }

    /// Lighter-weight scoring that reuses an already-computed edge image.
    /// Use this when scoring many candidates against the same source image.
    public static func score(
      horizonMask: HorizonMask,
      edgeImage: PixelatedImage
    ) -> HorizonScore {
        let mask = horizonMask.image
        let horizonY = extractHorizonYPerColumn(from: mask)
        let smoothness = smoothnessScore(horizonY: horizonY)
        let edgeAlignment = edgeAlignmentScore(
          horizonY: horizonY,
          edgeImage: edgeImage,
          tolerance: 3
        )
        let coverage = coverageScore(horizonY: horizonY, imageHeight: mask.height)
        let consistency = localConsistencyScore(horizonY: horizonY)
        let flatness = flatnessScore(horizonY: horizonY)

        return HorizonScore(
          smoothnessScore: smoothness,
          edgeAlignmentScore: edgeAlignment,
          coverageScore: coverage,
          localConsistencyScore: consistency,
          flatnessScore: flatness
        )
    }
}
