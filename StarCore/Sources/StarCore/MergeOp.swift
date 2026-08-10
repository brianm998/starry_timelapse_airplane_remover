import Foundation
import logging

public final class MergeOp: AsyncOperation, @unchecked Sendable {
    let frame: FrameAirplaneRemover
    let errorClosure: (String) -> Void

    init(
      frame: FrameAirplaneRemover,
      rawImageBytes: UInt64 = 0,
      memoryMultiplier: UInt64? = nil,
      errorClosure: @escaping (String) -> Void
    ) {
        self.frame = frame
        self.errorClosure = errorClosure
        super.init(for: .merge, rawImageBytes: rawImageBytes, memoryMultiplier: memoryMultiplier)
        self.name = "merge frame \(frame.frameIndex)"
    }

    /// Nothing to merge for a frame whose output is already written.
    ///
    /// The same test `asyncExecute` has always made first — hoisted ahead of the
    /// reservation, because a merge reserves `effectiveMergeMemoryMultiplier` × the
    /// working frame and was taking all of it in order to read one enum.  The check
    /// inside `asyncExecute` stays: it is the one that holds for a frame that completes
    /// between this being asked and the op running.
    public override func hasWorkToDo() async -> Bool {
        await frame.processingState() != .complete
    }

    public override func asyncExecute() async {
        guard !Task.isCancelled else {
            Log.d("frame \(frame.frameIndex) merge cancelled")
            return
        }
        do {
            Log.d("frame \(frame.frameIndex) start")

            if await frame.processingState() == .complete {
                Log.i("frame \(frame.frameIndex) already complete, skipping merge")
                return
            }

            guard !Task.isCancelled else {
                Log.d("frame \(frame.frameIndex) merge cancelled after state check")
                return
            }

            switch await frame.cleanMethod {
            case .automatic(let usesOutliers):
                if usesOutliers {
                    await frame.set(state: .secondClassification)
                    guard !Task.isCancelled else {
                        Log.d("frame \(frame.frameIndex) merge cancelled before decision tree (auto)")
                        return
                    }
                    await frame.applyDecisionTreeToAllOutliers()
                    guard !Task.isCancelled else {
                        Log.d("frame \(frame.frameIndex) merge cancelled after decision tree (auto)")
                        return
                    }
                }
                try await frame.finishAuto(useOutliers: usesOutliers)
            case .selective:
                await frame.set(state: .secondClassification)
                guard !Task.isCancelled else {
                    Log.d("frame \(frame.frameIndex) merge cancelled before decision tree (selective)")
                    return
                }
                await frame.applyDecisionTreeToAllOutliers()
                guard !Task.isCancelled else {
                    Log.d("frame \(frame.frameIndex) merge cancelled after decision tree (selective)")
                    return
                }
                try await frame.finishSelective()
            }
            Log.d("frame \(frame.frameIndex) done")
        } catch is CancellationError {
            Log.d("frame \(frame.frameIndex) merge cancelled")
        } catch {
            let str = "frame \(frame.frameIndex) error during merge: \(error)"
            Log.e(str)
            errorClosure(str)
        }
    }
}
