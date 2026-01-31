import Foundation
import logging

public final class MergeOp: AsyncOperation {
    let frame: FrameContext

    init(frame: FrameContext) {
        self.frame = frame
    }

    override func execute() {
        task = Task {
            defer {
                Log.d("frame \(frame.index) end")
                finish()
            }
            Log.d("frame \(frame.index) start")
            try? await Task.sleep(nanoseconds: UInt64.random(in: 2_000_000_000...10_000_000_000))
            //try? await frame.remover.warpAndMedianMerge()
        }
    }
}
