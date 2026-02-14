import Foundation
import logging

final class HomographyOp: AsyncOperation, @unchecked Sendable {
    let frame: FrameAirplaneRemover
    let mode: FrameViewMode
    let errorClosure: (String) -> Void
    
    init(
      forStars: Bool,
      frame: FrameAirplaneRemover,
      mode: FrameViewMode,
      errorClosure: @escaping (String) -> Void
    ) {
        self.frame = frame
        self.mode = mode
        self.errorClosure = errorClosure
        if forStars {
            super.init(for: .starHomography)
        } else {
            super.init(for: .earthHomography)
        }
    }

    override func execute() {
        task = Task {
            defer {
                Log.d("frame \(frame.frameIndex) end")
                finish()
            }
            do {
                Log.d("frame \(frame.frameIndex) start")
                let _ = try await frame.loadOrCreateHomography(of: mode)
                Log.d("frame \(frame.frameIndex) done")
            } catch {
                let str = "frame \(frame.frameIndex) error during homography calculation: \(error)"
                Log.e(str)
                errorClosure(str)
            }
        }
    }
}
