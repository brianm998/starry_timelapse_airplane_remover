import Foundation
import logging

final class AlignmentValidationOp: AsyncOperation {
    let frames: [FrameContext]

    init(frames: [FrameContext]) {
        self.frames = frames
    }

    override func execute() {
        task = Task {
            defer {
                Log.d("end")
                finish()
            }

            Log.d("start")
            try? await Task.sleep(nanoseconds: UInt64.random(in: 2_000_000_000...10_000_000_000))
//            try? await FrameAirplaneRemover.validateAlignments(frames)
        }
    }
}
