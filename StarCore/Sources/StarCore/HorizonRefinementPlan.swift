import Foundation
import logging

/// The horizon refinement a sequence is owed after the user repaints a reference horizon.
///
/// Painting a reference changes the horizon of every frame that interpolates from it, so the merged
/// horizon masks of those frames, and the output rendered through them, are stale.  The user is asked
/// whether to redo that now or later, and in the meantime the sequence has to know which frames are
/// owed what: the ones shown in pending orange, the one button that picks the work up, the next
/// ordinary run that takes it on its way past.  This is that record, and the rules for changing it.
///
/// It was part of the macOS gui's `ImageSequenceViewModel` and is here so that the daemon, which the
/// Kotlin client drives, keeps the same record by the same rules.  It is a value: it holds frame
/// *indices* and nothing else, and the questions that depend on what is on disk (does this frame have
/// output the old horizon went into? which frames are references?) are answered by the caller and passed
/// in, because the gui and the daemon know that in different ways.  What the transitions do to the files
/// is `HorizonRefinementEffects`.
public struct HorizonRefinementPlan: Sendable, Equatable {

    /// Reference frame indices updated since the refinement last ran.
    public private(set) var updatedReferences: Set<Int> = []

    /// Non-reference frame indices that will be re-refined when the user asks for it.
    public private(set) var affected: Set<Int> = []

    /// Frames whose finished render "Later" already took away, and which therefore need one again
    /// when the pending refinement finally runs.
    ///
    /// Without this the re-run would look at the disk, find no output for them, and take that for
    /// "never processed -- nothing to re-render", leaving the frames it had just refined with no
    /// picture at all.
    public private(set) var stripped: Set<Int> = []

    /// What the refinement run in progress took out of the sets above, held until it finishes.
    ///
    /// A run claims them: it empties them so that a reference painted while it works starts a fresh
    /// set.  A run that is stopped has to give them back -- the frames it never got to are still
    /// marked orange, and without this the button that would pick them up is disabled, leaving the
    /// sequence in a state only re-painting a reference gets out of.
    public private(set) var inFlight: Claim?

    public struct Claim: Sendable, Equatable {
        public var affected: Set<Int>
        public var references: Set<Int>
        public var stripped: Set<Int>

        public init(affected: Set<Int>, references: Set<Int>, stripped: Set<Int>) {
            self.affected = affected
            self.references = references
            self.stripped = stripped
        }
    }

    public init() {}

    /// Frame output whose presence means a frame has to be rendered again when the horizon under it
    /// moves -- the same set `FrameAirplaneRemover.deleteMergeOutput` deletes.
    public static let outputTypes: Set<FrameViewMode> =
      [.autoProcessed, .autoSelectiveProcessed, .selectiveProcessed, .final]

    // MARK: - what is owed

    /// Whether there is horizon refinement work waiting -- what enables a "Re-run Horizon
    /// Refinement" button, and what makes the next ordinary run pick the work up on its way past.
    ///
    /// Not just the interpolated frames between references: a reference painted next to another one has
    /// no frames in between to re-refine, and still has its own output to render again -- and after
    /// "Later" has taken that output away, the record of having done so is the only thing left saying
    /// the frame is owed one.
    ///
    /// - Parameter hasOutput: whether a frame has output the changed horizon went into.
    public func hasPending(hasOutput: (Int) -> Bool) -> Bool {
        !affected.isEmpty
          || !stripped.isEmpty
          || !framesNeedingRerender(updatedReferences, hasOutput: hasOutput).isEmpty
    }

    /// Of `indices`, the frames a re-run would have to render again: the ones that still have output
    /// the changed horizon went into, and the ones whose output "Later" has already taken away on the
    /// same grounds.
    public func framesNeedingRerender(_ indices: Set<Int>, hasOutput: (Int) -> Bool) -> Set<Int> {
        indices.filter { stripped.contains($0) || hasOutput($0) }
    }

    /// The interpolated frames a set of just-updated references leaves stale: everything between each
    /// of them and the references either side, plus whatever was already pending, minus the reference
    /// frames themselves -- a reference serves its painted mask directly and has nothing to re-refine.
    ///
    /// `referenceIndices` must be sorted; it is scanned for the neighbours of each updated reference.
    ///
    /// `stillPending` is not derivable from the rest, which is why it is a parameter: a run over part of
    /// the sequence takes on the frames of a span it covers and leaves the remainder, and the references
    /// bounding that span say nothing about which half is which.  Recomputing without it would drop
    /// those frames -- and their marks -- leaving frames with no output that nothing records as being
    /// owed one.
    public static func affectedFrames(
      updatedReferences: Set<Int>,
      referenceIndices: [Int],
      stillPending: Set<Int> = [],
      frameCount: Int
    ) -> Set<Int> {
        var affected = stillPending
        for updatedIdx in updatedReferences {
            let prevRef = referenceIndices.last(where: { $0 < updatedIdx }) ?? -1
            let nextRef = referenceIndices.first(where: { $0 > updatedIdx }) ?? frameCount
            for i in (prevRef + 1)..<nextRef {
                affected.insert(i)
            }
        }
        return affected.subtracting(referenceIndices)
    }

    // MARK: - changes

    /// How a change moved frames in and out of the pending set, for whatever draws them in orange.
    public struct PendingChange: Sendable, Equatable {
        public var nowPending: Set<Int>
        public var noLongerPending: Set<Int>

        public init(nowPending: Set<Int>, noLongerPending: Set<Int>) {
            self.nowPending = nowPending
            self.noLongerPending = noLongerPending
        }
    }

    /// A reference horizon was saved: recompute the affected set.
    ///
    /// Union with what is already pending rather than replacing it.  The recomputed set is derived from
    /// the references still waiting, so it cannot know about a span a run over part of the sequence took
    /// half of and left the rest of -- and dropping those frames would take their marks with it.
    /// Reference frames are excluded either way: the frame just painted was an interpolated one until a
    /// moment ago.
    ///
    /// - Parameter referenceIndices: every frame that has a painted reference, sorted.
    @discardableResult
    public mutating func recordReferenceUpdated(
      frameIndex: Int,
      referenceIndices: [Int],
      frameCount: Int
    ) -> PendingChange {
        updatedReferences.insert(frameIndex)
        let old = affected
        let new = Self.affectedFrames(
          updatedReferences: updatedReferences,
          referenceIndices: referenceIndices,
          stillPending: old,
          frameCount: frameCount
        )
        affected = new
        return PendingChange(nowPending: new, noLongerPending: old.subtracting(new))
    }

    /// The numbers the "re-run now, or later?" question quotes.
    public struct PromptCounts: Sendable, Equatable {
        /// Frames the run would touch.
        public var frameCount: Int
        /// Of those, the ones it would render again.
        public var renderCount: Int

        public init(frameCount: Int, renderCount: Int) {
            self.frameCount = frameCount
            self.renderCount = renderCount
        }
    }

    /// What to ask the user after a reference was saved, or nil when there is nothing to ask about:
    /// no horizons to recompute and no output to render again.
    ///
    /// The counts are to be captured when the question goes up rather than read live: answering it
    /// clears the sets they are counted from.
    public func promptCounts(hasOutput: (Int) -> Bool) -> PromptCounts? {
        let toRender = framesNeedingRerender(affected.union(updatedReferences), hasOutput: hasOutput)
        guard !affected.isEmpty || !toRender.isEmpty else { return nil }
        return PromptCounts(frameCount: affected.union(toRender).count, renderCount: toRender.count)
    }

    /// The frames "Later" acts on: everything pending, and the references.  The caller works out which
    /// of them have output to take away and passes those to `markStripped`.
    public var deferralFrameIndices: [Int] { affected.union(updatedReferences).sorted() }

    /// Record frames whose output "Later" took away.
    public mutating func markStripped(_ indices: Set<Int>) { stripped.formUnion(indices) }

    /// What a run that is about to start takes on of the pending work, so that pressing "Process" does
    /// it without the user having to know it was owed.
    public struct Taken: Sendable, Equatable {
        /// The frames this run now owns.
        public var frames: Set<Int>
        /// Every reference that is waiting, not only the ones being taken on: a partial run can be
        /// redoing frames whose merged mask is computed from a reference outside its range, and reading
        /// that reference's old numbers would rebuild the old horizon.
        public var referencesToClear: Set<Int>
        /// How much was pending in all, for the log.
        public var pendingCount: Int

        public init(frames: Set<Int>, referencesToClear: Set<Int>, pendingCount: Int) {
            self.frames = frames
            self.referencesToClear = referencesToClear
            self.pendingCount = pendingCount
        }
    }

    /// Take the pending work in `range` (the frames the run covers; nil for the whole sequence) into a
    /// run.  Work outside it stays pending: a run over part of the sequence must not clear the marks on
    /// frames it was never going to reach.  Nil when there is nothing there to take.
    public mutating func take(range: ClosedRange<Int>? = nil) -> Taken? {
        let pending = affected.union(updatedReferences).union(stripped)
        let taking = range.map { covered in pending.filter { covered.contains($0) } } ?? pending
        guard !taking.isEmpty else { return nil }
        let referencesToClear = updatedReferences
        updatedReferences.subtract(taking)
        affected.subtract(taking)
        stripped.subtract(taking)
        return Taken(frames: taking, referencesToClear: referencesToClear, pendingCount: pending.count)
    }

    /// Claim all of the pending work for a refinement run that is about to start ("Re-run Horizon
    /// Refinement", or answering the question with "Now"): empties the sets, and keeps what was in them
    /// as the in-flight claim until `finishClaim`, or `returnInFlight` if the run is stopped.
    public mutating func claimAll() -> Claim {
        let claim = Claim(affected: affected, references: updatedReferences, stripped: stripped)
        updatedReferences = []
        affected = []
        stripped = []
        inFlight = claim
        return claim
    }

    /// The run finished, so it keeps what it claimed (or there was nothing to run).
    public mutating func finishClaim() { inFlight = nil }

    /// Give back what a stopped run had claimed, so the user can run it again.
    ///
    /// Everything it claimed, including the frames it had already finished: there is no per-frame
    /// record of which merges completed, and redoing one costs a merge and changes nothing --
    /// `deleteMergeOutput` and the merge that follows land on the same output either way.
    ///
    /// Returns the affected frames, which are pending again, or nil if no run was in flight.
    @discardableResult
    public mutating func returnInFlight() -> Set<Int>? {
        guard let claim = inFlight else { return nil }
        inFlight = nil
        updatedReferences.formUnion(claim.references)
        affected.formUnion(claim.affected)
        stripped.formUnion(claim.stripped)
        return affected
    }
}

/// What the transitions of a `HorizonRefinementPlan` do to the files and caches under the frames.
public enum HorizonRefinementEffects {

    /// Take away what a changed reference has made wrong: the cached statistics of the references, the
    /// stale merged horizon masks of `maskFrames`, and the output the old horizon was baked into
    /// (`outputFrames`).  It queues no operation: `FrameGraphBuilder` builds a horizon merge for a frame
    /// whose mask is missing and a merge for a frame whose output is, so a frame with neither is a frame
    /// every run already knows to redo -- in this session or the next.
    ///
    /// This is both "Later" and what a run that takes pending work on its way past does first (before
    /// the graph is built, which surveys the disk and would otherwise find all of it still there).
    public static func strip(
      references: Set<Int>,
      maskFrames: [FrameAirplaneRemover],
      outputFrames: [FrameAirplaneRemover]
    ) async {
        // In memory and cheap, and the merged masks about to be rebuilt are computed from it -- a run
        // that read the old numbers would rebuild the old horizon.
        for idx in references {
            await ReferenceHorizonStatsRegistry.shared.clearStats(for: idx)
        }
        await withTaskGroup(of: Void.self) { group in
            for frame in maskFrames { group.addTask { await frame.discardMergedHorizon() } }
            for frame in outputFrames { group.addTask { await frame.deleteMergeOutput() } }
        }
    }

    /// The first half of a refinement run: clear the references' statistics and delete the output the
    /// old horizon went into, so that each frame is re-composited with the new one.  Alignment output is
    /// preserved.  The frames do not have to wait for each other to do it.
    public static func prepareRerun(references: Set<Int>, mergeFrames: [FrameAirplaneRemover]) async {
        for idx in references {
            await ReferenceHorizonStatsRegistry.shared.clearStats(for: idx)
        }
        await withTaskGroup(of: Void.self) { group in
            for frame in mergeFrames {
                group.addTask { await frame.deleteMergeOutput() }
            }
        }
    }
}
