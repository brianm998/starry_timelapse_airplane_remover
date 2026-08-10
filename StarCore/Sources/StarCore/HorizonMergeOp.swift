import Foundation
import logging

final class HorizonMergeOp: AsyncOperation, @unchecked Sendable {
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
        super.init(for: .mergedHorizon, rawImageBytes: rawImageBytes,
                   memoryMultiplier: memoryMultiplier)
        self.name = "horizon merge frame \(frame.frameIndex)"
    }

    func addDependencies(from opMap: [Int: Operation]) async {
        for neighborIndex in await frame.getHorizonMergeIndices() {
            if let origHorizonOp = opMap[neighborIndex] {
                self.addDependency(origHorizonOp)
            } else {
                // Expected, not a warning: `FrameGraphBuilder` does not build a
                // detection op for a neighbour whose mask is already on disk, and this
                // merge reads those from disk anyway.  A neighbour with no mask and no
                // op would be a problem, but that combination cannot arise — the
                // builder skips only on the mask being present.
                Log.d("frame \(neighborIndex) has no horizon op — its mask is on disk")
            }
        }
    }

    /// Nothing to merge when the merged mask is already on disk.
    ///
    /// The op's only durable output is that file; everything else it does is populate
    /// `cachedFinalHorizonMask`, which any later reader re-materialises on demand.  So
    /// when the file is there, running this costs a full-res decode plus a row-by-row
    /// bounds scan (~120ms at 6000×4000) and produces nothing.
    ///
    /// Note a frame with a painted reference horizon is *also* a no-op here — the
    /// reference wins over the merged file in `loadOrCreateMergedHorizonMask` and
    /// nothing is written either way — but that case is left to run rather than
    /// predicted, since the builder already handles the sequence-wide form of it via
    /// `Config.hasStaticReferenceHorizon`.
    override func hasWorkToDo() async -> Bool {
        !frame.mergedHorizonMaskExistsOnDisk()
    }

    override func asyncExecute() async {
        do {
            Log.d("frame \(frame.frameIndex) starting")

            // Read before doing the work, not after: creating a merged mask puts the
            // frame through `.mergingHorizon`, so asked afterwards this is never
            // `.complete` and the release below would never fire.
            let wasComplete = await frame.processingState() == .complete

            _ = try await frame.loadOrCreateFinalHorizonMask()

            // Drop what that just cached if this frame was already finished.
            //
            // `cachedFinalHorizonMask` is normally released by the `.complete`
            // transition in `set(state:)`, but a frame that was *already* complete when
            // the sequence loaded never makes that transition again — so on a re-run
            // nothing releases it and every mask loaded here is retained for the life
            // of the process.  At 6000×4000 that is 24MB per frame, ~31GB across a
            // 1300-frame sequence, and the MemoryMonitor ledger never hears about any
            // of it.  Once process footprint crosses the budget the reality brake holds
            // every reservation and the queue drops to one forced admission per
            // `forcedAdmissionInterval` — which is how a merely wasteful re-run turns
            // into a stalled one.
            if wasComplete {
                await frame.releaseRecomputableState()
            }
            Log.d("frame \(frame.frameIndex) done")
        } catch {
            let str = "frame \(frame.frameIndex) error during horizon merge: \(error)"
            Log.e(str)
            errorClosure(str)
        }
    }
}
