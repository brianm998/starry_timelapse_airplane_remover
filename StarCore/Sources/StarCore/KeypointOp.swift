import Foundation
import logging

final class KeypointOp: AsyncOperation, @unchecked Sendable {
    let frame: FrameAirplaneRemover
    let mode: FrameViewMode
    let errorClosure: (String) -> Void
    private let limiter: KeypointLimiter

    /// Whether `acquireExecutionSlot()` actually got a slot, so `releaseExecutionSlot()`
    /// knows whether it owes one back.  Needs no lock: both hooks run in order on the
    /// single task `AsyncOperation.start()` creates, and nothing else touches it.
    private var heldLimiterSlot = false

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
    // the keypoint phase outright, and the guarded-`acquired` flag that used to live
    // here was treating a symptom of that — `KeypointLimiter` has the full account.  The
    // gate gained a wait, so this op can take it the same way every other caller does:
    // by suspending, rather than lying to the queue about whether it can run.
    override func acquireExecutionSlot() async {
        heldLimiterSlot = await limiter.acquire()
        if !heldLimiterSlot {
            Log.w("frame \(frame.frameIndex) timed out waiting for a keypoint slot, proceeding")
        }
    }

    override func releaseExecutionSlot() async {
        if heldLimiterSlot {
            limiter.release()
            heldLimiterSlot = false
        }
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
