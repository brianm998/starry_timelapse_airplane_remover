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

    // Note there is no `isReady` override.  Gating readiness on the limiter deadlocked
    // the keypoint phase outright — `KeypointLimiter` has the full account.  The gate
    // lives in `acquireExecutionSlot()` now, which suspends this op's task instead of
    // lying to the queue about whether it can run.
    override func acquireExecutionSlot() async {
        await limiter.acquire()
    }

    override func releaseExecutionSlot() async {
        limiter.release()
    }

    override func asyncExecute() async {
        guard !Task.isCancelled else {
            Log.d("frame \(frame.frameIndex) keypoint detection cancelled")
            return
        }
        do {
            Log.d("frame \(frame.frameIndex) start")
            _ = try await frame.loadOrCreateOCVFeatures(of: mode)
            Log.d("frame \(frame.frameIndex) done")
        } catch is CancellationError {
            Log.d("frame \(frame.frameIndex) keypoint detection cancelled")
        } catch {
            let str = "frame \(frame.frameIndex) error during keypoint detection: \(error)"
            Log.e(str)
            errorClosure(str)
        }
    }
}
