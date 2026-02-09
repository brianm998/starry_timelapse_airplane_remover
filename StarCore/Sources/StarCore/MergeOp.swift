import Foundation
import logging

public final class MergeOp: AsyncOperation, @unchecked Sendable {
    let frame: FrameAirplaneRemover
    let errorClosure: (String) -> Void

    init(frame: FrameAirplaneRemover, errorClosure: @escaping (String) -> Void) {
        self.frame = frame
        self.errorClosure = errorClosure
    }

    override func execute() {
        task = Task {
            defer {
                Log.d("frame \(frame.frameIndex) end")
                finish()
            }
            do {
                Log.d("frame \(frame.frameIndex) start")
                // XXX this re-writes any existing files, should skip if already there
                try await frame.finishAuto(useOutliers: false)
                Log.d("frame \(frame.frameIndex) done")
            } catch {
                let str = "frame \(frame.frameIndex) error during merge: \(error)"
                Log.e(str)
                errorClosure(str)
            }
        }
    }
}
