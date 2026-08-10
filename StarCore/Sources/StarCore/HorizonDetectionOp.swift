import Foundation
import logging

final class HorizonDetectionOp: AsyncOperation, @unchecked Sendable {
    let frame: FrameAirplaneRemover
    let errorClosure: (String) -> Void

    /// True when a `HorizonAccumulator` is registered on this frame, so that
    /// `accumulateDetectedHorizon` below is a real side effect rather than a no-op.
    /// Set by `FrameGraphBuilder`, which decides whether there is an accumulator at all.
    private let feedsAccumulator: Bool

    init(
      frame: FrameAirplaneRemover,
      rawImageBytes: UInt64 = 0,
      memoryMultiplier: UInt64? = nil,
      feedsAccumulator: Bool = false,
      errorClosure: @escaping (String) -> Void
    ) {
        self.frame = frame
        self.feedsAccumulator = feedsAccumulator
        self.errorClosure = errorClosure
        super.init(for: .horizon, rawImageBytes: rawImageBytes,
                   memoryMultiplier: memoryMultiplier)
        self.name = "horizon detect frame \(frame.frameIndex)"
    }

    /// Nothing to detect when the mask is already on disk — unless this op is also
    /// feeding the accumulator, in which case the load is the work.
    ///
    /// Worth being careful about, because "skip it, the merge will read the file
    /// instead" is a trap on the static path: `HorizonAccumulator.finalize` folds in
    /// whatever was not accumulated via `ia_accumulate_from_files`, which is a *serial*
    /// loop of decodes inside one op.  Running the same decodes as N parallel ops that
    /// each fold their own mask in is the entire reason the accumulator exists, so when
    /// it is in play these ops still run.
    ///
    /// `FrameGraphBuilder` registers an accumulator only when the merged mask is
    /// actually missing, so on a re-run this is false and the mask on disk wins.
    override func hasWorkToDo() async -> Bool {
        if feedsAccumulator { return true }
        return !frame.horizonMaskExistsOnDisk()
    }

    override func asyncExecute() async {
        guard !Task.isCancelled else {
            Log.d("frame \(frame.frameIndex) horizon detection cancelled")
            return
        }
        do {
            Log.d("frame \(frame.frameIndex) starting")
            let mask = try await frame.loadOrCreateHorizonMask()
            await frame.accumulateDetectedHorizon(mask)
            Log.d("frame \(frame.frameIndex) done")
        } catch is CancellationError {
            Log.d("frame \(frame.frameIndex) horizon detection cancelled")
        } catch {
            let str = "frame \(frame.frameIndex) error during horizon detection: \(error)"
            Log.e(str)
            errorClosure(str)
        }
    }
}
