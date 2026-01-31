import Foundation
import logging

final class HomographyOp: AsyncOperation {
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
            try? await Task.sleep(nanoseconds: UInt64.random(in: 2_000_000_000...10_000_000_000))
//            try? await frame.remover.computeNeighborHomographies(mode: mode)
        }
    }
}
