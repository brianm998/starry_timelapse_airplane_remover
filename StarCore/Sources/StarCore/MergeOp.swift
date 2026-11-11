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

    /// Test seam: while the file `<tempOutputPath>/merge.hold` exists, the merge of every frame from the index it holds (its text; the first
    /// frame when empty) on waits, so a UI test can keep a run going for as long as its steps take and then let it finish (delete the file).
    /// Alignment and outliers go on meanwhile, and the run is reported as in progress.  Nil when there is no such file, which is all a real run
    /// ever sees: one stat per merge.
    static func heldFromFrame(tempOutputPath: String) -> Int? {
        guard let data = FileManager.default.contents(atPath: tempOutputPath + "/merge.hold") else { return nil }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return Int(text) ?? 0
    }

    /// How long a held merge waits before the hold is looked at again.
    static let holdRecheck: Duration = .milliseconds(250)

    /// Waits while the hold holds this frame; returns at once when the op is cancelled (a superseding start, Stop), so the hold never keeps
    /// `cancelAllOperationsAndWait` from draining.
    private func holdWhileAsked() async {
        let tempOutputPath = await frame.configManager.config().tempOutputPath
        var logged = false
        while !Task.isCancelled,
              let heldFrom = Self.heldFromFrame(tempOutputPath: tempOutputPath),
              frame.frameIndex >= heldFrom {
            if !logged {
                Log.i("frame \(frame.frameIndex) merge held by \(tempOutputPath)/merge.hold")
                logged = true
            }
            try? await Task.sleep(for: Self.holdRecheck)
        }
        if logged { Log.i("frame \(frame.frameIndex) merge no longer held") }
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

            await holdWhileAsked()
            guard !Task.isCancelled else {
                Log.d("frame \(frame.frameIndex) merge cancelled while held")
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
                    await frame.applyDecisionTreeToAllOutliers(keepingUserDecisions: true)
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
                await frame.applyDecisionTreeToAllOutliers(keepingUserDecisions: true)
                guard !Task.isCancelled else {
                    Log.d("frame \(frame.frameIndex) merge cancelled after decision tree (selective)")
                    return
                }
                try await frame.finishSelective()
            case .dirtySky:
                // no decision tree: the dirty methods keep every bad signal
                try await frame.finishDirty(portion: .sky)
            case .dirtyEarth:
                try await frame.finishDirty(portion: .earth)
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
