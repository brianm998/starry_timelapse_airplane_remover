import Foundation
import logging

final class KeypointOp: AsyncOperation {
    let frame: FrameAirplaneRemover
    let mode: FrameViewMode

    init(frame: FrameAirplaneRemover, mode: FrameViewMode) {
        self.frame = frame
        self.mode = mode
    }

    override func execute() {
        task = Task {
            defer {
                Log.d("frame \(frame.frameIndex) end")
                finish()
            }
            Log.d("frame \(frame.frameIndex) start")

            _ = try? await frame.loadOrCreateOCVFeatures(of: mode)
        }
    }
}
