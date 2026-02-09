import Foundation
import logging

final class KeypointOp: AsyncOperation, @unchecked Sendable {
    let frame: FrameAirplaneRemover
    let mode: FrameViewMode
    let errorClosure: (String) -> Void
    
    init(
      frame: FrameAirplaneRemover,
      mode: FrameViewMode,
      errorClosure: @escaping (String) -> Void
    ) {
        self.frame = frame
        self.mode = mode
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
                _ = try await frame.loadOrCreateOCVFeatures(of: mode)
                Log.d("frame \(frame.frameIndex) done")
            } catch {
                let str = "frame \(frame.frameIndex) error during keypoint detection: \(error)"
                Log.e(str)
                errorClosure(str)
            }
        }
    }
}
