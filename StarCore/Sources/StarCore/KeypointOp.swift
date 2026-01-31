import Foundation
import logging

final class KeypointOp: AsyncOperation {
    let frame: FrameContext
    let mode: FrameViewMode

    init(frame: FrameContext, mode: FrameViewMode) {
        self.frame = frame
        self.mode = mode
    }

    override func execute() {
        task = Task {
            defer {
                Log.d("frame \(frame.index) end")
                finish()
            }
            Log.d("frame \(frame.index) start")
            try? await Task.sleep(nanoseconds: UInt64.random(in: 2_000_000_000...10_000_000_000))
            //_ = try? await frame.remover.loadOrCreateOCVFeatures(of: mode)
        }
    }
}
