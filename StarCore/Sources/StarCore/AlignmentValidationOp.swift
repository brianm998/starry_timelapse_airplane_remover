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
                /*

                 For moving videos, figure out how to detect the curve and match ones to it
                 that are too far away

                 */
                Log.w("validation for moving tripods is not implemented yet")
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
            if let homography = await frame.getNeighborStarHomography() {
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
              neighborStarHomography: HomographyResultsCodable(
                for: frame.frameIndex,
                with: medianHomography.neighborHomography
              )
            )
        }
        Log.d("done validating static star alignment")
    }
}
