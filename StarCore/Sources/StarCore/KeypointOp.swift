import Foundation
import logging

final class KeypointOp: AsyncOperation, @unchecked Sendable {
    let frame: FrameAirplaneRemover
    let mode: FrameViewMode
    let errorClosure: (String) -> Void
    private let limiter: KeypointLimiter
    // Prevents double-acquiring a limiter slot if isReady is polled multiple times.
    //
    // Needs the lock: OperationQueue polls isReady from arbitrary threads, so an
    // unguarded check-then-set let two concurrent polls both see acquired == false and
    // both succeed at tryAcquire. Only one slot is ever released in finish(), so the
    // other leaked permanently — each leak shrinking the effective keypoint cap for the
    // rest of the run.
    private let acquireLock = NSLock()
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
        acquireLock.lock()
        defer { acquireLock.unlock() }
        if acquired { return super.isReady }
        guard super.isReady else { return false }
        if limiter.tryAcquire() {
            acquired = true
            return true
        }
        return false
    }

    override func finish() {
        // Release the lock before calling super: super.finish() drives KVO, which can
        // re-enter isReady on another thread.
        acquireLock.lock()
        let held = acquired
        acquired = false
        acquireLock.unlock()

        if held { limiter.release() }
        super.finish()
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
