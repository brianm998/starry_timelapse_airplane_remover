import Foundation
import logging

final class KeypointOp: AsyncOperation, @unchecked Sendable {
    let frame: FrameAirplaneRemover
    let mode: FrameViewMode
    let errorClosure: (String) -> Void
    private let limiter: KeypointLimiter
    // Prevents double-acquiring a limiter slot if isReady is polled multiple times.
    private var acquired = false

    init(
      forStars: Bool,
      frame: FrameAirplaneRemover,
      mode: FrameViewMode,
      limiter: KeypointLimiter,
      rawImageBytes: UInt64 = 0,
      memoryMultiplier: UInt64? = nil,
      errorClosure: @escaping (String) -> Void
    ) {
        self.frame = frame
        self.mode = mode
        self.limiter = limiter
        self.errorClosure = errorClosure
        if forStars {
            super.init(for: .starKeypoints, rawImageBytes: rawImageBytes, memoryMultiplier: memoryMultiplier)
            self.name = "star keypoints for frame \(frame.frameIndex)"
        } else {
            super.init(for: .earthKeypoints, rawImageBytes: rawImageBytes, memoryMultiplier: memoryMultiplier)
            self.name = "earth keypoints for frame \(frame.frameIndex)"
        }
    }

    override var isReady: Bool {
        if acquired { return super.isReady }
        guard super.isReady else { return false }
        if limiter.tryAcquire() {
            acquired = true
            return true
        }
        return false
    }

    override func finish() {
        if acquired {
            limiter.release()
            acquired = false
        }
        super.finish()
    }

    override func asyncExecute() async {
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
