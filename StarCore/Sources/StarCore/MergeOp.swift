import Foundation
import logging

public final class MergeOp: AsyncOperation, @unchecked Sendable {
    let frame: FrameAirplaneRemover

    init(frame: FrameAirplaneRemover) {
        self.frame = frame
    }

    override func execute() {
        task = Task {
            defer {
                Log.d("frame \(frame.frameIndex) end")
                finish()
            }
            Log.d("frame \(frame.frameIndex) start")
            try? await frame.finishAuto(useOutliers: false)
        }
    }
}
