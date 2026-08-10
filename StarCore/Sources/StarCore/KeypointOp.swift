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

    /// Where this frame's feature set is persisted, resolved once at init so
    /// `hasWorkToDo()` is a single `stat` with no config lookup and no actor hop.
    /// Nil when the mode has no keypoint file, which is not a thing to skip over — see
    /// `hasWorkToDo()`.
    private let keypointPath: String?

    init(
      forStars: Bool,
      frame: FrameAirplaneRemover,
      mode: FrameViewMode,
      limiter: KeypointLimiter,
      rawImageBytes: UInt64 = 0,
      memoryMultiplier: UInt64? = nil,
      keypointPath: String? = nil,
      errorClosure: @escaping (String) -> Void
    ) {
        self.frame = frame
        self.mode = mode
        self.limiter = limiter
        self.keypointPath = keypointPath
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
    /// Nothing to detect when the feature file this op would write is already there.
    ///
    /// The backstop for `FrameGraphBuilder`, which asks the same question and normally
    /// does not build this op at all.  It earns its keep for the ops that *are* built:
    /// detection reserves 50× the working frame, so an op that gets this far only to
    /// find its file present would hold 7.2GB at 6000×4000 for the 45ms it takes to
    /// parse it — and on a re-run that reservation is what paces the whole queue.
    ///
    /// Skipping leaves `frame.skyKeyPoints` unpopulated, which is fine: the homography
    /// stage reads a stored homography without needing them at all, and on the path
    /// where it does need them `loadOrCreateOCVFeatures(of:selfGating:)` loads the file
    /// — taking a limiter slot and a reservation of its own to do it.
    override func hasWorkToDo() async -> Bool {
        // No path means no cache to check, not "already done".
        guard let keypointPath else { return true }
        return !FileManager.default.fileExists(atPath: keypointPath)
    }

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

            // Before the work: detection puts the frame through `.starKeypoints`, so
            // asked afterwards this is never `.complete`.
            let wasComplete = await frame.processingState() == .complete

            _ = try await frame.loadOrCreateOCVFeatures(of: mode)

            // Detection masks with the final horizon, which caches it on the frame.  A
            // frame that was already complete when the sequence loaded will never make
            // the `.complete` transition that normally releases that, so release it
            // here — see the same note in `HorizonMergeOp.asyncExecute`.
            if wasComplete {
                await frame.releaseRecomputableState()
            }
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
