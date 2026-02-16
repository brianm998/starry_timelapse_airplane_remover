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

    /// Combined weighted score. Higher is better.
    public var totalScore: Double {
        // Smoothness is the strongest signal - a jerky horizon is almost certainly wrong.
        // Edge alignment confirms the horizon sits on a real intensity boundary.
        // Coverage prevents degenerate all-sky or all-ground results.
        let smoothnessWeight = 0.5
        let edgeAlignmentWeight = 0.3
        let coverageWeight = 0.2
        return smoothnessScore * smoothnessWeight +
               edgeAlignmentScore * edgeAlignmentWeight +
               coverageScore * coverageWeight
    }

    public var description: String {
        String(format: "HorizonScore(total=%.3f, smooth=%.3f, edge=%.3f, coverage=%.3f)",
               totalScore, smoothnessScore, edgeAlignmentScore, coverageScore)
    }
}

/// The result of a single parameter combination trial during adaptive horizon search.
struct HorizonSearchResult: Sendable {
    let cropAmount: Double      // the bottomPercentage used
    let stripWidth: Int         // the stripWidth used (in full-resolution pixels)
    let horizonMask: HorizonMask
    let score: HorizonScore
}

/// Tracks the best-known parameters from previous frames to narrow future searches.
public actor AdaptiveHorizonState {
    private var lastBestCropAmount: Double?
    private var lastBestStripWidth: Int?
    private var frameCount: Int = 0

    public init() {}

    /// Record the best parameters found for a frame.
    func recordBest(cropAmount: Double, stripWidth: Int) {
        lastBestCropAmount = cropAmount
        lastBestStripWidth = stripWidth
        frameCount += 1
    }

    /// Get narrowed crop amounts for subsequent frames.
    /// After the first frame, we center the search around the previous best
    /// and narrow the range.
    func narrowedCropAmounts(
      defaults: [Double],
      narrowingRange: Double
    ) -> [Double] {
        guard let lastBest = lastBestCropAmount, frameCount > 0 else {
            return defaults
        }

        // Build a narrowed set: [lastBest - range, lastBest, lastBest + range]
        // Clamp to valid 0-100 range, deduplicate
        let candidates = [
            lastBest - narrowingRange,
            lastBest,
            lastBest + narrowingRange
        ].map { max(0, min(100, $0)) }

        // Deduplicate values that are very close after clamping
        var result: [Double] = []
        for c in candidates {
            if !result.contains(where: { abs($0 - c) < 1.0 }) {
                result.append(c)
            }
        }
        return result.sorted()
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
enum HorizonScoring {

    /// Extract the horizon Y coordinate per column from a binary mask.
    /// The horizon Y is defined as the topmost black (ground) pixel in each column.
    /// Returns nil for columns that are all-white (all sky) or all-black (all ground).
    static func extractHorizonYPerColumn(from mask: PixelatedImage) -> [Int?] {
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
    static func smoothnessScore(horizonY: [Int?]) -> Double {
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
    static func edgeAlignmentScore(
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

    /// Compute coverage score: penalize degenerate results that are nearly all-sky
    /// or all-ground.
    /// `horizonY` is the per-column horizon Y from the mask.
    /// `imageHeight` is the total height of the mask image.
    static func coverageScore(horizonY: [Int?], imageHeight: Int) -> Double {
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
    static func score(
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

        return HorizonScore(
          smoothnessScore: smoothness,
          edgeAlignmentScore: edgeAlignment,
          coverageScore: coverage
        )
    }

    /// Lighter-weight scoring that reuses an already-computed edge image.
    /// Use this when scoring many candidates against the same source image.
    static func score(
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

        return HorizonScore(
          smoothnessScore: smoothness,
          edgeAlignmentScore: edgeAlignment,
          coverageScore: coverage
        )
    }
}
