import Foundation
import logging

final class HomographyOp: AsyncOperation, @unchecked Sendable {
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
            let _ = try await frame.loadOrCreateHomography(of: mode)
        }
    }
}
