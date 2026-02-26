import Foundation
import logging

final class KeypointOp: AsyncOperation, @unchecked Sendable {
    let frame: FrameAirplaneRemover
    let mode: FrameViewMode
    let errorClosure: (String) -> Void
    private let limiter: KeypointLimiter

    init(
      forStars: Bool,
      frame: FrameAirplaneRemover,
      mode: FrameViewMode,
      limiter: KeypointLimiter,
      errorClosure: @escaping (String) -> Void
    ) {
        self.frame = frame
        self.mode = mode
        self.limiter = limiter
        self.errorClosure = errorClosure
        if forStars {
            super.init(for: .starKeypoints)
            self.name = "star keypoints for frame \(frame.frameIndex)"
        } else {
            super.init(for: .earthKeypoints)
            self.name = "earth keypoints for frame \(frame.frameIndex)"
        }
    }

    override var isReady: Bool {
        super.isReady && limiter.tryAcquire()
    }

    override func finish() {
        limiter.release()
        super.finish()
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
