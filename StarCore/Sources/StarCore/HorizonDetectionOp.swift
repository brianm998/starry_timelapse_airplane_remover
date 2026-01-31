import Foundation
import logging

final class HorizonDetectionOp: AsyncOperation {
    let frame: FrameAirplaneRemover

    init(frame: FrameAirplaneRemover) {
        self.frame = frame
    }

    override func execute() {
        task = Task {
            defer { finish() }
            Log.d("frame \(frame.frameIndex) starting")
            _ = try await frame.loadOrCreateHorizonMask()
            Log.d("frame \(frame.frameIndex) done")
        }
    }
}
