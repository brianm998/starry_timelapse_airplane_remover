import Foundation
import logging

/*
 This operation takes the full detected homography for the entire sequence,
 and then cleans it up to make sure it is not wrong anywhere.
 */
final class AlignmentValidationOp: AsyncOperation, @unchecked Sendable {
    let frames: [FrameAirplaneRemover]
    let configManager: ConfigManager
    
    init(frames: [FrameAirplaneRemover], configManager: ConfigManager) {
        self.frames = frames
        self.configManager = configManager
    }

    override func execute() {
        task = Task {
            defer {
                Log.d("end")
                finish()
            }

            Log.d("start")
            let config = await configManager.config()
            if config.tripodHeadWasMoving {
                await validateMovingStarAlignment()
            } else {
                // tripod was stationary
                try await self.validateStaticStarAlignment()
            }

            // XXX still need to handle earth alignment if enabled
        }
    }

    // runs on a static sequence after homography is known for each frame and its neighbors
    // finds the 'best' homography and applies it to all frames, to keep the video smooth.
    private func validateStaticStarAlignment() async throws {
        Log.d("doing static star alignment validation")
        var homographies: [HomographyResultsCodable] = []
        for frame in frames {
            if let homography = await frame.getNeighborStarHomography(),
               homography.alignmentLooksOk
            {
                homographies.append(homography)
            }
        }
        if homographies.count == 0 {
            Log.e("ERROR, canceling no homographies found")
            self.cancel()
            // have this abort the operation
            return
        }
        Log.d("found \(homographies.count) neighbor homography groups")

        // sort by composite deviation (average deviation per once frame distance)
        homographies.sort { $0.compositeDeviation < $1.compositeDeviation }

        let medianHomography = homographies[homographies.count/2]
        Log.d("found median homography at frameIndex \(medianHomography.frameIndex)")
        
        // apply the chosen median homography to all frames 
        for frame in frames {
            await frame.set(
              neighborStarHomography: medianHomography.adjust(
                for: frame.frameIndex
              )
            )
        }
        Log.d("done validating static star alignment")
    }

    private func validateMovingStarAlignment() async {
        Log.d("doing moving tripod star alignment validation")

        let kalman = HomographyKalman()

        // Absolute pose per frame (log space)
        var poses: [Int: [Double]] = [:]

        var orderedFrames = frames.sorted { $0.frameIndex < $1.frameIndex }

        // --- Forward pass
        for frame in orderedFrames {
            let t = frame.frameIndex

            guard let result = await frame.getNeighborStarHomography() else {
                if let prev = poses[t - 1] {
                    poses[t] = prev   // constant-velocity fallback
                }
                continue
            }

            // Collect relative measurements
            var measurements: [[Double]] = []

            for warp in result.neighborHomography {
                guard
                  let h = warp.homography,
                  warp.alignmentState == .homographySuccess
                else { continue }

                let n = warp.frameIndex
                let logH = HomographyLieMapping.log(h)

                if let poseN = poses[n] {
                    // log(P(t)) ≈ log(P(n)) − log(H)
                    let estimateT = zip(poseN, logH).map { $0 - $1 }
                    measurements.append(estimateT)
                }
            }

            if let best = measurements.first {
                poses[t] = best
            } else if let prev = poses[t - 1] {
                poses[t] = prev
            }
        }

        // --- RTS smoothing
        let smoothedPoses = rtsSmoothPoses(
          orderedFrames.map { $0.frameIndex },
          poses: poses
        )

         // --- Apply result
        for frame in orderedFrames {
            let t = frame.frameIndex
            guard let poseT = smoothedPoses[t] else { continue }

            guard let original = await frame.getNeighborStarHomography() else { continue }

            var rebuilt: [AlignmentWarpInfoCodable] = []

            for warp in original.neighborHomography {
                let n = warp.frameIndex
                guard let poseN = poses[n] else { continue }

                // H(t ← n) = P(t)^-1 · P(n)
                let delta = zip(poseN, poseT).map { $0 - $1 }
                let h = HomographyLieMapping.exp(delta)

                rebuilt.append(
                  AlignmentWarpInfoCodable(
                    homography: h,
                    deviation: homographyDeviation(h),
                    alignmentState: .homographySuccess,
                    frameIndex: n
                  )
                )
            }

            await frame.set(
              neighborStarHomography: HomographyResultsCodable(
                for: t,
                with: rebuilt
              )
            )
        }

        Log.d("done validating moving star alignment")
    }

}

private func confidence(from result: HomographyResultsCodable) -> Double {
    // simple, effective
    return max(0.1, 1.0 / result.compositeDeviation)
}

func rtsSmoothPoses(
    _ order: [Int],
    poses: [Int: [Double]]
) -> [Int: [Double]] {
    guard order.count > 1 else { return poses }

    var smoothed = poses

    for i in stride(from: order.count - 2, through: 0, by: -1) {
        let t = order[i]
        let t1 = order[i + 1]

        guard
            let xT = poses[t],
            let xT1 = poses[t1],
            let xT1s = smoothed[t1]
        else { continue }

        // Identity dynamics: xₖ = xₖ₊₁
        let correction = zip(xT1s, xT1).map { $0 - $1 }
        smoothed[t] = zip(xT, correction).map(+)
    }

    return smoothed
}
