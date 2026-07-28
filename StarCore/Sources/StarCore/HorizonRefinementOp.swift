import Foundation
import logging

/// Recomputes the merged horizon mask for one frame after a manual reference
/// horizon edit.  Wraps `frame.recomputeMergedHorizon()` so the work runs
/// through the FrameGraphBuilder queue (with concurrency limit and memory
/// reservation) and shows up in the operations panel.
public final class HorizonRefinementOp: AsyncOperation, @unchecked Sendable {
    public let frame: FrameAirplaneRemover
    let errorClosure: (String) -> Void
    let onCompletion: @Sendable (FrameAirplaneRemover) async -> Void

    init(
      frame: FrameAirplaneRemover,
      rawImageBytes: UInt64 = 0,
      memoryMultiplier: UInt64? = nil,
      errorClosure: @escaping (String) -> Void,
      onCompletion: @escaping @Sendable (FrameAirplaneRemover) async -> Void = { _ in }
    ) {
        self.frame = frame
        self.errorClosure = errorClosure
        self.onCompletion = onCompletion
        super.init(for: .mergedHorizon, rawImageBytes: rawImageBytes,
                   memoryMultiplier: memoryMultiplier)
        self.name = "horizon refinement frame \(frame.frameIndex)"
    }

    public override func asyncExecute() async {
        guard !Task.isCancelled else {
            Log.d("frame \(frame.frameIndex) horizon refinement cancelled")
            return
        }
        do {
            // recomputeMergedHorizon sets the frame's state to .mergingHorizon.
            // For frames that haven't reached alignment yet there is no following
            // op to advance them, so they'd appear stuck on "horizon" in the
            // filmstrip.  Save state before the call and restore it after — the
            // dependent MergeOp (when one exists) will advance .mergingHorizon
            // to .complete on its own.
            let hasAlignment =
                frame.imageAccessor.imageExists(frameIndex: frame.frameIndex,
                                                ofType: .starAligned, atSize: .original) ||
                frame.imageAccessor.imageExists(frameIndex: frame.frameIndex,
                                                ofType: .earthAligned, atSize: .original)
            let stateBeforeMerge = hasAlignment ? nil : await frame.processingState()
            try await frame.recomputeMergedHorizon()
            if let savedState = stateBeforeMerge {
                await frame.set(state: savedState)
            }
            await onCompletion(frame)
        } catch is CancellationError {
            Log.d("frame \(frame.frameIndex) horizon refinement cancelled")
        } catch {
            let str = "frame \(frame.frameIndex) error during horizon refinement: \(error)"
            Log.e(str)
            errorClosure(str)
        }
    }
}
