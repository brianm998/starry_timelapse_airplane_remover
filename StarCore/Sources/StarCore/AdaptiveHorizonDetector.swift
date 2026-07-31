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

    /// Penalizes horizon lines whose average Y position sits very close to the
    /// Otsu crop boundary. When the crop is set too low (below the real horizon),
    /// the pipeline detects the crop boundary itself as the horizon. This penalty
    /// is a second *multiplier* on the total score.
    /// 1.0 = horizon is well above the crop boundary, 0.0 = horizon is at the boundary.
    public let cropBoundaryScore: Double

    /// Combined weighted score. Higher is better.
    public var totalScore: Double {
        // Smoothness is a strong signal - a jerky horizon is almost certainly wrong.
        // Edge alignment confirms the horizon sits on a real intensity boundary.
        // Coverage prevents degenerate all-sky or all-ground results.
        // Local consistency catches isolated spike artifacts from too-narrow strips.
        //
        // Flatness is treated as a *multiplier*, not an additive term.
        // A flat horizon line almost always means the crop boundary was mistaken for
        // the real horizon. The line is maximally smooth and edge-aligned at the crop
        // boundary, so an additive flatness penalty cannot overcome those high scores.
        let smoothnessWeight    = 0.30
        let edgeAlignmentWeight = 0.30
        let coverageWeight      = 0.15
        let localConsistencyWeight = 0.25
        let additive = smoothnessScore    * smoothnessWeight +
                       edgeAlignmentScore * edgeAlignmentWeight +
                       coverageScore      * coverageWeight +
                       localConsistencyScore * localConsistencyWeight
        // cropBoundaryScore is a multiplier:  
        // it can suppress the total to near-zero when the detected horizon is
        // degenerate (flat crop-boundary artifact).
        return additive * cropBoundaryScore
    }

    public init(
      smoothnessScore: Double,
      edgeAlignmentScore: Double,
      coverageScore: Double,
      localConsistencyScore: Double,
      cropBoundaryScore: Double
    ) {
        self.smoothnessScore      = smoothnessScore
        self.edgeAlignmentScore   = edgeAlignmentScore
        self.coverageScore        = coverageScore
        self.localConsistencyScore = localConsistencyScore
        self.cropBoundaryScore    = cropBoundaryScore
    }

    public var description: String {
        String(format: "HorizonScore(total=%.3f, smooth=%.3f, edge=%.3f, coverage=%.3f, consist=%.3f, cropBnd=%.3f×)",
               totalScore, smoothnessScore, edgeAlignmentScore, coverageScore,
               localConsistencyScore, cropBoundaryScore)
    }
}

/// The result of a single parameter combination trial during adaptive horizon search.
/// For Otsu results, `cropAmount` is set; `lambda`, `sobelW`, `cannyW` are nil.
/// For DP results, `lambda`, `sobelW`, `cannyW` are set; `cropAmount` is -1 (sentinel).
struct HorizonSearchResult: Sendable {
    let cropAmount: Double      // the bottomPercentage used (Otsu); -1 for DP results
    let horizonMask: HorizonMask
    let score: HorizonScore
    // DP-specific parameters (nil for Otsu results)
    let lambda: Double?
    let sobelW: Double?
    let cannyW: Double?

    /// Convenience initialiser for Otsu results (no DP params).
    init(cropAmount: Double, horizonMask: HorizonMask, score: HorizonScore) {
        self.cropAmount  = cropAmount
        self.horizonMask = horizonMask
        self.score       = score
        self.lambda      = nil
        self.sobelW      = nil
        self.cannyW      = nil
    }

    /// Full initialiser used for DP results (all fields).
    init(cropAmount: Double, horizonMask: HorizonMask, score: HorizonScore,
         lambda: Double?, sobelW: Double?, cannyW: Double?) {
        self.cropAmount  = cropAmount
        self.horizonMask = horizonMask
        self.score       = score
        self.lambda      = lambda
        self.sobelW      = sobelW
        self.cannyW      = cannyW
    }
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
    private var lastFirstPassStep: Double?
    private var frameCount: Int = 0

    public init() {}

    /// Record the best parameters found for a frame.
    func recordBest(cropAmount: Double, firstPassStep: Double) {
        lastBestCropAmount = cropAmount
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
    ///
    /// The score rewards gentle, natural variation and penalises two failure modes:
    ///
    ///  1. **Too rough** (large stddev): a jerky, spike-filled horizon is almost
    ///     certainly wrong. Penalty rises quickly with stddev via the classic
    ///     `1 / (1 + stddev)` term.
    ///
    ///  2. **Too flat** (near-zero stddev): a perfectly constant horizon line is
    ///     almost certainly the crop boundary, not the real horizon. A real
    ///     horizon shifts gently across the frame; a truly flat line has zero
    ///     derivative variance. We penalise this with a Gaussian lower-bound term
    ///     `1 - exp(-stddev² / (2 * naturalStddev²))` that rises from 0 at
    ///     stddev=0 toward 1 as stddev approaches `naturalStddev` (default ≈ 3 px).
    ///
    /// The combined score peaks around stddev ≈ 2–4 pixels and falls for both
    /// flatter and rougher lines.
    ///
    /// Columns with nil values are skipped in the derivative computation.
    public static func smoothnessScore(
      horizonY: [Int?],
      naturalStddev: Double = 3.0
    ) -> Double {
        // Compute column-to-column differences where both neighbors are non-nil.
        //
        // The `horizonY.count > 0` guard is load-bearing, not defensive: with an empty array
        // `1..<0` is an invalid range and traps.  The "not enough data points" guard below was
        // clearly meant to cover this, but it only runs after the loop.
        var diffs: [Double] = []
        if horizonY.count > 0 {
            for i in 1..<horizonY.count {
                if let prev = horizonY[i - 1], let curr = horizonY[i] {
                    diffs.append(Double(curr - prev))
                }
            }
        }

        guard diffs.count > 1 else {
            // Not enough data points - return neutral score
            return 0.5
        }

        let mean = diffs.reduce(0, +) / Double(diffs.count)
        let variance = diffs.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(diffs.count)
        let stddev = sqrt(variance)

        // Upper-roughness penalty: score drops as the line becomes more erratic.
        // stddev=0  → 1.0,  stddev=5 → 0.17,  stddev=10 → 0.09
        let upperPenalty = 1.0 / (1.0 + stddev)

        // Lower-flatness penalty: score rises from 0 toward 1 as stddev increases
        // from 0, reaching ~0.63 at stddev=naturalStddev and ~0.86 at 2×naturalStddev.
        // This directly penalises robotically flat (crop-boundary) detections.
        let lowerPenalty = 1.0 - exp(-(stddev * stddev) / (2.0 * naturalStddev * naturalStddev))

        return upperPenalty * lowerPenalty
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

    /// Compute crop-boundary proximity score.
    ///
    /// When the Otsu crop amount is set too low (below the real horizon), the
    /// pipeline detects the crop boundary itself as the horizon. The crop boundary
    /// is a perfectly straight, perfectly smooth, well-edge-aligned line — so the
    /// other scores cannot distinguish it from a real horizon.
    ///
    /// This score penalises results whose average horizon Y is very close to the
    /// crop boundary Y. It is applied as a *multiplier* on the total score.
    ///
    /// - `cropBoundaryY`: the Y pixel coordinate of the Otsu crop boundary
    ///   (the topmost row of the cropped region, i.e. `imageHeight * cropFraction`).
    /// - `tolerancePixels`: how far from the boundary (in pixels) counts as "at the
    ///   boundary". Default 8 px. Results within this distance get a heavy penalty.
    ///
    /// Score transitions from 0.05 (within tolerancePixels) to 1.0 (≥ 3× tolerance
    /// away) using a smooth sigmoid ramp.
    public static func cropBoundaryScore(
      horizonY: [Int?],
      cropBoundaryY: Int,
      tolerancePixels: Double = 8
    ) -> Double {
        let defined = horizonY.compactMap { $0 }
        guard !defined.isEmpty else { return 1.0 }

        var goodColumns = 0
        var totalColumns = 0
        
        for y in horizonY {
            if let y {
                totalColumns += 1
                let dist = abs(Double(y) - Double(cropBoundaryY))
                if dist >= tolerancePixels {
                    goodColumns += 1
                }
            }
        }

        return Double(goodColumns)/Double(totalColumns)
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
    ///
    /// - `cropBoundaryY`: the Y pixel coordinate of the Otsu crop boundary in the
    ///   mask's coordinate space (i.e. `imageHeight * cropFraction`). Pass `nil`
    ///   (default) to skip the crop-boundary penalty (e.g. when scoring at full
    ///   resolution where the boundary is not meaningful).
    public static func score(
      horizonMask: HorizonMask,
      originalImage: PixelatedImage,
      cannyMinThreshold: Double,
      cannyMaxThreshold: Double,
      useL2Gradient: Bool,
      cropBoundaryY: Int? = nil
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
        let cropBoundary: Double
        if let boundaryY = cropBoundaryY {
            cropBoundary = cropBoundaryScore(horizonY: horizonY, cropBoundaryY: boundaryY)
        } else {
            cropBoundary = 0.999 // no penalty when boundary is unknown
        }

        return HorizonScore(
          smoothnessScore: smoothness,
          edgeAlignmentScore: edgeAlignment,
          coverageScore: coverage,
          localConsistencyScore: consistency,
          cropBoundaryScore: cropBoundary
        )
    }

    /// Lighter-weight scoring that reuses an already-computed edge image.
    /// Use this when scoring many candidates against the same source image.
    ///
    /// - `cropBoundaryY`: the Y pixel coordinate of the Otsu crop boundary in the
    ///   mask's coordinate space. Pass `nil` (default) to skip the penalty.
    public static func score(
      horizonMask: HorizonMask,
      edgeImage: PixelatedImage,
      cropBoundaryY: Int? = nil
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
        let cropBoundary: Double
        if let boundaryY = cropBoundaryY {
            cropBoundary = cropBoundaryScore(horizonY: horizonY, cropBoundaryY: boundaryY)
        } else {
            cropBoundary = 0.99 // no penalty when boundary is unknown
        }

        return HorizonScore(
          smoothnessScore: smoothness,
          edgeAlignmentScore: edgeAlignment,
          coverageScore: coverage,
          localConsistencyScore: consistency,
          cropBoundaryScore: cropBoundary
        )
    }
}
