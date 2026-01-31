import Foundation
import logging

final class HorizonDetectionOp: AsyncOperation {
    let frame: FrameContext

    init(frame: FrameContext) {
        self.frame = frame
    }

    override func execute() {
        task = Task {
            defer { finish() }
            Log.d("frame \(frame.index) starting")
            try? await Task.sleep(nanoseconds: UInt64.random(in: 2_000_000_000...10_000_000_000))
//            try? await Task.sleep(nanoseconds: 10_000_000)
            Log.d("frame \(frame.index) done")
        }
    }
}
