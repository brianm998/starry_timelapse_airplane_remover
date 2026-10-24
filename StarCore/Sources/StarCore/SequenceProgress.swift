import Foundation
import logging

/// How far a previous run got on a sequence, read off what it left on disk.
///
/// Taken once, when the sequence is opened, and not updated afterwards — the name says so.
/// A run started from the modal this feeds reports itself through `ProcessingModalView`,
/// which measures live operations; this is the other question, asked before there are any.
public struct SequenceProgress: Equatable, Sendable {

    /// The sequence directory's name, so the panel can say which sequence it is describing.
    public let sequenceName: String

    public let frameCount: Int

    /// Frames whose finished output image is already written.  The headline number, and the
    /// one that decides whether there is anything left to do: it is exactly the test
    /// `MergeOp` skips on, so a sequence where this equals `frameCount` builds no merges.
    public let framesComplete: Int

    /// One entry per step a run under this configuration would take, in the order
    /// `ProcessingSteps.types` gives them.
    public let steps: [ProcessingStepProgress]

    public init(sequenceName: String, frameCount: Int, framesComplete: Int, steps: [ProcessingStepProgress]) {
        self.sequenceName = sequenceName
        self.frameCount = frameCount
        self.framesComplete = framesComplete
        self.steps = steps
    }

    /// Nothing at all has been done to this sequence yet.
    ///
    /// Over every step rather than over `framesComplete`, because the steps are where the
    /// hours go: a sequence with all its keypoints detected and no frames merged has had
    /// most of the work done to it, and calling that "not started" would invite the user to
    /// throw it away.
    public var isUntouched: Bool { steps.allSatisfy { $0.completed == 0 } }

    /// Every frame has its output written, so a run would have nothing to merge.
    ///
    /// Deliberately not "every step is full": the alignment steps are the ones whose
    /// artifacts a changed setting throws away, and a sequence can be finished and still
    /// be missing the keypoint files whose results were folded into it long ago.  What the
    /// user asked for is the finished frames, and those are on disk or they are not.
    public var isComplete: Bool { frameCount > 0 && framesComplete >= frameCount }
}

/// Reads `SequenceProgress` off the disk, and does the arithmetic that turns "how many
/// frames have this artifact" into the bars the panel draws.
///
/// Split from the view for the same reason `ProcessingSteps` is: this is the part that can
/// be wrong without looking wrong.
public enum SequenceProgressSurvey {

    /// One bar per step, with the frames whose artifact is already present at the finished
    /// end of it and the rest of the sequence behind them.
    ///
    /// `alreadyDone` and `queued` rather than `done` and `queued` because nothing here is
    /// this run's work — no run has started — and that is the distinction
    /// `ProcessingStepProgress` draws between the two.
    ///
    /// A step missing from `framesOnDisk` gets a bar at zero rather than no bar at all: it
    /// is a step this configuration takes, and the count of what it has finished is a
    /// number the survey went and looked for.
    public static func steps(
      for types: [OperationType],
      frameCount: Int,
      framesOnDisk: [OperationType: Int]
    ) -> [ProcessingStepProgress] {
        types.map { type in
            let done = min(max(0, framesOnDisk[type] ?? 0), frameCount)
            return ProcessingStepProgress(
              type: type,
              queued: frameCount - done,
              running: 0,
              done: 0,
              alreadyDone: done
            )
        }
    }

    /// Survey a loaded sequence.
    ///
    /// Every per-frame question is one `stat` — the same predicates `FrameGraphBuilder`
    /// surveys with before it decides which operations to build, for the same reason: the
    /// alternative is to answer "has this already been done?" by doing it (see the note on
    /// `FrameAirplaneRemover`'s predicates).  At ~6us each a 1300 frame sequence costs
    /// tens of milliseconds, which is why this can run on the way in.
    ///
    /// Takes what is on disk at face value.  A run started afterwards may delete some of
    /// it — `FrameGraphBuilder.invalidateStaleArtifacts` throws away any stage whose
    /// settings have changed since it was written — but the settings that wrote these are
    /// the ones in the config file that was just opened, so at this moment the two agree.
    public static func survey(
      frames: [FrameAirplaneRemover],
      config: Config,
      homographyDatabase: HomographyDatabase
    ) async -> SequenceProgress {
        let types = ProcessingSteps.types(for: config)
        var framesOnDisk: [OperationType: Int] = [:]

        func count(_ type: OperationType,
                   _ isOnDisk: (FrameAirplaneRemover) -> Bool)
        {
            guard types.contains(type) else { return }
            framesOnDisk[type] = frames.filter(isOnDisk).count
        }

        count(.horizon)        { $0.horizonMaskExistsOnDisk() }
        // Per frame, even for a static sequence, where one merge op produces the mask for
        // the whole sequence and hard-links it to every frame.  The question here is how
        // much of the sequence has a merged horizon, not how many operations ran.
        count(.mergedHorizon)  { $0.mergedHorizonMaskExistsOnDisk() }
        count(.starKeypoints)  { $0.keypointsExistOnDisk(ofType: .starAligned, config: config) }
        count(.earthKeypoints) { $0.keypointsExistOnDisk(ofType: .earthAligned, config: config) }
        count(.horizonConsensus) {
            HorizonConsensusStore.exists(frameIndex: $0.frameIndex, config: config)
        }
        count(.outliers)       { $0.outliersExistOnDisk(config: config) }
        count(.merge)          { $0.outputFileExistsOnDisk() }

        // The two alignment steps keep their results in one database for the whole
        // sequence rather than a file per frame, so they are surveyed with a query each.
        let sequenceIndices = Set(frames.map(\.frameIndex))
        let alignmentSteps: [(OperationType, HomographyDatabase.HomographyType)] =
          [(.starHomography, .star), (.earthHomography, .earth)]
        for (type, stored) in alignmentSteps where types.contains(type) {
            do {
                let indices = try await homographyDatabase.storedFrameIndices(type: stored)
                framesOnDisk[type] = indices.intersection(sequenceIndices).count
            } catch {
                // Unreadable is not the same as absent, and neither is worth failing an
                // open over: the bar sits at zero and the run recomputes, which is what
                // would happen anyway.
                Log.w("could not survey stored \(stored.rawValue) homographies: \(error)")
            }
        }

        return SequenceProgress(
          sequenceName: config.imageSequenceDirname,
          frameCount: frames.count,
          framesComplete: framesOnDisk[.merge] ?? 0,
          steps: steps(for: types, frameCount: frames.count, framesOnDisk: framesOnDisk)
        )
    }
}
