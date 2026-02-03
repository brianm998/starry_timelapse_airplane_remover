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
        var states: [Int: KalmanState] = [:]
        var orderedFrames = frames.sorted { $0.frameIndex < $1.frameIndex }

        // --- Forward pass
        for frame in orderedFrames {
            let idx = frame.frameIndex

            if let result = await frame.getNeighborStarHomography(),
               result.alignmentLooksOk,
               let h = bestHomography(from: result)
            {
                let logH = HomographyLieMapping.log(h)

                if let prev = states[idx - 1] {
                    let predicted = kalman.predict(prev)
                    let weight = confidence(from: result)
                    states[idx] = kalman.update(predicted, measurement: logH, weight: weight)
                } else {
                    states[idx] = kalman.initialState(from: logH)
                }
            } else if let prev = states[idx - 1] {
                states[idx] = kalman.predict(prev)
            }
        }

        // --- RTS smoothing
        let smoothed = rtsSmooth(states.values.sorted { $0.x[0] < $1.x[0] })

        // --- Apply result
        for (frame, state) in zip(orderedFrames, smoothed) {
            let h = HomographyLieMapping.exp(state.x)
            let warp = AlignmentWarpInfoCodable(
              homography: h,
              deviation: homographyDeviation(h),
              alignmentState: .homographySuccess,
              frameIndex: frame.frameIndex
            )

            await frame.set(
              neighborStarHomography: HomographyResultsCodable(
                for: frame.frameIndex,
                with: [warp]
              )
            )
        }

        Log.d("done validating moving star alignment")
    }

}

private func bestHomography(from result: HomographyResultsCodable) -> [Double]? {
    result.neighborHomography
        .filter { $0.homography != nil }
        .min { $0.deviation < $1.deviation }?
        .homography
}

private func confidence(from result: HomographyResultsCodable) -> Double {
    // simple, effective
    return max(0.1, 1.0 / result.compositeDeviation)
}
