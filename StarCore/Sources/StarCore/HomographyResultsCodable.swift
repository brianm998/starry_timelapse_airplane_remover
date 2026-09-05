import Foundation
import logging
import StarCppBridge

public struct HomographyResultsCodable: Codable, Sendable {
    public let frameIndex: Int
    public let neighborHomography: [AlignmentWarpInfoCodable]

    public var total: Int { neighborHomography.count }

    public init(for frameIndex: Int,
                with neighborHomography: [AlignmentWarpInfoCodable])
    {
        self.frameIndex = frameIndex
        self.neighborHomography = neighborHomography.sorted { $0.frameIndex < $1.frameIndex }
    }
    
    public init(from result: HomographyResult) {
        self.frameIndex = Int(result.frameIndex)
        self.neighborHomography = result.warpInfo
          .map { $0.toCodable() }
          .sorted { $0.frameIndex < $1.frameIndex }
    }

    // There is deliberately no `adjust(for:)` here any more.  Shifting every
    // neighbor's frame index by a constant looks like the obvious way to move one
    // frame's set onto another, but it also carries over the source's neighbor *count*
    // and offset shape, and those legitimately vary: frames near the ends of a sequence
    // have fewer neighbors than interior ones.  Re-targeting a set is always relative to
    // the offsets the destination frame actually has — see
    // `extrapolateNeighborHomography` and `retargetNeighborHomography`.

    func mappedHomography() -> [Int: MatWrapper] {
        var ret: [Int: MatWrapper] = [:]
        for homography in neighborHomography {
            let warpInfo = AlignmentWarpInfo.from(codable: homography)
            let offset = homography.frameIndex - frameIndex
            ret[offset] = warpInfo.homography
        }
        return ret
    }

    // the average of the deviation of neighbors by frame distance
    public var compositeDeviation: Double {
        var ret: Double = 0
        var count: Double = 0
        
        for homographyInfo in neighborHomography {
            if let homography = homographyInfo.homography {
                let offset = Double(abs(homographyInfo.frameIndex - frameIndex))
                ret += homographyDeviation(homography)/offset
                count += 1
            }
        }

        ret /= count
        
        return ret
    }

    /// How `partitionWarps` sorted one frame's neighbor homographies.
    ///
    /// `suspect` is what the heuristics below distrust, not what is known to be wrong.
    /// Every check in here is internal to this one frame's own set — magnitude, slope
    /// uniformity, and residual from a line fit through its *own* neighbors — so a set
    /// that is smooth but collectively at the wrong rate passes, and a correct set
    /// measured while the pan rate is changing can be flagged.  Callers that can bring
    /// outside evidence to bear should do so before discarding a suspect warp; see
    /// `HomographyReciprocity` and `validateMovingStarAlignment`.
    public struct WarpPartition: Sendable {
        public let good: [AlignmentWarpInfoCodable]
        public let suspect: [AlignmentWarpInfoCodable]
    }

    // apply some basic heurstics to the neighbor homography to see if it looks ok
    // weeds out some obvously bad homographies
    public var alignmentLooksOk: Bool {
        let partition = partitionWarps()
        return !partition.good.isEmpty && partition.suspect.isEmpty
    }

    /// Sort this frame's neighbor homographies by the heuristics `alignmentLooksOk`
    /// applies, but report the split instead of collapsing it to one Bool.  Same
    /// checks, same thresholds — `alignmentLooksOk` is defined in terms of this.
    public func partitionWarps() -> WarpPartition {

        var slopes: [Double] = []

        for homography in neighborHomography {
            let frameDistance = abs(self.frameIndex-Int(homography.frameIndex))
            slopes.append(homography.deviation/Double(frameDistance))
        }

        var goodWarps: [AlignmentWarpInfoCodable] = []
        var badWarps: [AlignmentWarpInfoCodable] = []

        slopes.sort(by: { $0 < $1 })

        // Translation smoothness check: in a well-aligned moving timelapse,
        // each neighbor's tx and ty should track a roughly linear function of
        // signed distance.  A bad RANSAC fit can produce a matrix whose
        // overall L2 deviation falls in the right range (because ty
        // dominates) but whose tx is off by several pixels in the wrong
        // direction — exactly the failure that turns a frame into a
        // "brightest-stars-only" flash in the rendered video.  Fit
        // tx ≈ ax·d + bx and ty ≈ ay·d + by across all neighbors with a
        // homography and flag any neighbor whose residual exceeds the
        // threshold below.
        //
        // We need a meaningful regression to do this; with fewer than four
        // points the line is over-fit and we skip the check.
        let translationPoints: [(d: Double, tx: Double, ty: Double)] =
          neighborHomography.compactMap { h in
              guard let m = h.homography, m.count >= 6 else { return nil }
              let d = Double(h.frameIndex - self.frameIndex)
              return (d: d, tx: m[2], ty: m[5])
          }
        let translationFit: (txLine: (a: Double, b: Double),
                             tyLine: (a: Double, b: Double))?
        if translationPoints.count >= 4 {
            let xs = translationPoints.map(\.d)
            let txLine = linearFit(x: xs, y: translationPoints.map(\.tx))
            let tyLine = linearFit(x: xs, y: translationPoints.map(\.ty))
            translationFit = (txLine, tyLine)
        } else {
            translationFit = nil
        }
        // 3 px: empirically larger than the typical residual on a well-aligned
        // frame (≤ ~1.5 px in our test sequences) but well below the multi-px
        // RANSAC outlier signatures we want to catch.
        let maxTranslationResidual: Double = 3.0

        let medianIndex = slopes.count/2
        if medianIndex < slopes.count {
            let medianSlope = slopes[medianIndex]
            //Log.d("frame \(frameIndex) got medianSlope \(medianSlope)")
            for homography in neighborHomography {
                let frameDistance = abs(self.frameIndex-Int(homography.frameIndex))
                let alignmentSlope = homography.deviation/Double(frameDistance)
                /*
                 three checks here:
                 - deviation isn't too large in general
                   fast clouds without stars can get large deviation
                 - alignment slope is close to constant
                   deviation should be evenly spaced by frame distance
                 - tx and ty are close to the line fit through all neighbors,
                   to catch RANSAC outliers whose deviation magnitude is in
                   range but whose translation direction is wrong
                 */


                let maxHomographyDivergence: Double = 20 // XXX make this a parameter
                let maxSlopeDivergence: Double = 1.08    // XXX make this a parameter

                var translationOk = true
                if let translationFit,
                   let m = homography.homography,
                   m.count >= 6
                {
                    let d = Double(homography.frameIndex - self.frameIndex)
                    let predictedTx = translationFit.txLine.a * d + translationFit.txLine.b
                    let predictedTy = translationFit.tyLine.a * d + translationFit.tyLine.b
                    if abs(m[2] - predictedTx) > maxTranslationResidual ||
                       abs(m[5] - predictedTy) > maxTranslationResidual {
                        translationOk = false
                    }
                }

                if homography.deviation < maxHomographyDivergence*Double(frameDistance),
                   alignmentSlope < medianSlope * maxSlopeDivergence,
                   alignmentSlope > medianSlope / maxSlopeDivergence,
                   translationOk
                {
                    // rough estimate
                    goodWarps.append(homography)
                } else {
                    badWarps.append(homography)
                }
            }
        } else {
            Log.d("frame \(frameIndex) has NO medianSlope :(")
            // ALL FAIL :(
            // here we don't know the median, so all are bad :(
            badWarps = neighborHomography
        }

        return WarpPartition(good: goodWarps, suspect: badWarps)
    }

    /// This set restricted to the neighbor frame indices given, keeping each surviving
    /// entry's measured matrix and deviation exactly as they are.
    ///
    /// Dropping one neighbor costs the merge one source — it looks its homography up by
    /// offset (`ia_align_and_median_merge`) and simply has one fewer sample at each
    /// pixel — where replacing the whole set substitutes another frame's motion for this
    /// frame's.  Pruning is the smaller move of the two, so it is what a frame with a
    /// couple of doubtful neighbors gets.
    public func keeping(neighborFrameIndices keep: Set<Int>) -> HomographyResultsCodable {
        HomographyResultsCodable(
          for: frameIndex,
          with: neighborHomography.filter { keep.contains($0.frameIndex) }
        )
    }
}

/// Ordinary least-squares fit of `y = a·x + b`.  Returns `(0, mean(y))`
/// when `x` is constant or fewer than 2 points are given.
private func linearFit(x: [Double], y: [Double]) -> (a: Double, b: Double) {
    guard x.count >= 2, x.count == y.count else {
        let meanY = y.isEmpty ? 0 : y.reduce(0, +) / Double(y.count)
        return (0, meanY)
    }
    let n = Double(x.count)
    let sumX = x.reduce(0, +)
    let sumY = y.reduce(0, +)
    let sumXY = zip(x, y).reduce(0.0) { $0 + $1.0 * $1.1 }
    let sumXX = x.reduce(0.0) { $0 + $1 * $1 }
    let denom = n * sumXX - sumX * sumX
    guard abs(denom) > 1e-9 else { return (0, sumY / n) }
    let a = (n * sumXY - sumX * sumY) / denom
    let b = (sumY - a * sumX) / n
    return (a, b)
}

