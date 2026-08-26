import SwiftUI
import StarCore
import logging

/// How far a previous run got on a sequence, read off what it left on disk.
///
/// Taken once, when the sequence is opened, and not updated afterwards — the name says so.
/// A run started from the modal this feeds reports itself through `ProcessingModalView`,
/// which measures live operations; this is the other question, asked before there are any.
struct SequenceProgress: Equatable, Sendable {

    /// The sequence directory's name, so the panel can say which sequence it is describing.
    let sequenceName: String

    let frameCount: Int

    /// Frames whose finished output image is already written.  The headline number, and the
    /// one that decides whether there is anything left to do: it is exactly the test
    /// `MergeOp` skips on, so a sequence where this equals `frameCount` builds no merges.
    let framesComplete: Int

    /// One entry per step a run under this configuration would take, in the order
    /// `ProcessingSteps.types` gives them.
    let steps: [ProcessingStepProgress]

    /// Nothing at all has been done to this sequence yet.
    ///
    /// Over every step rather than over `framesComplete`, because the steps are where the
    /// hours go: a sequence with all its keypoints detected and no frames merged has had
    /// most of the work done to it, and calling that "not started" would invite the user to
    /// throw it away.
    var isUntouched: Bool { steps.allSatisfy { $0.completed == 0 } }

    /// Every frame has its output written, so a run would have nothing to merge.
    ///
    /// Deliberately not "every step is full": the alignment steps are the ones whose
    /// artifacts a changed setting throws away, and a sequence can be finished and still
    /// be missing the keypoint files whose results were folded into it long ago.  What the
    /// user asked for is the finished frames, and those are on disk or they are not.
    var isComplete: Bool { frameCount > 0 && framesComplete >= frameCount }
}

/// Reads `SequenceProgress` off the disk, and does the arithmetic that turns "how many
/// frames have this artifact" into the bars the panel draws.
///
/// Split from the view for the same reason `ProcessingSteps` is: this is the part that can
/// be wrong without looking wrong.
enum SequenceProgressSurvey {

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
    static func steps(
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
    static func survey(
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

/// The modal star puts up when a sequence is re-opened: how far the last run got, and the
/// one thing there is left to do about it — render the video if every frame is written,
/// finish the processing if not.
///
/// Presented as an `.overlay` on `ImageSequenceView` rather than as a `.sheet`, for two
/// reasons.  An overlay is sized by what it is attached to and reports nothing back, so
/// this panel can never become part of the window's minimum size — the mistake that once
/// let a hand-drawn alert grow the main window to 1452x3104 (see the note in
/// `ContentView`).  And the sheets are attached inside `BottomRightView`'s edit-mode
/// branch, which a re-opened sequence is not in: it opens in `.scrub`, where a `.sheet`
/// binding set here would flip a flag and show nothing.
///
/// This is only the wiring; everything drawn lives in `SequenceProgressPanel`, which takes
/// values rather than reading the view model and so can be rendered on its own.
struct SequenceProgressModalView: View {
    @Environment(ImageSequenceViewModel.self) var viewModel: ImageSequenceViewModel

    var body: some View {
        if let progress = viewModel.progressWhenOpened {
            SequenceProgressPanel(
              progress: progress,
              finishProcessing: { viewModel.finishProcessingOpenedSequence() },
              renderVideo: { viewModel.renderVideoForOpenedSequence() },
              dismiss: { viewModel.sequenceProgressModalShowing = false }
            )
        }
    }
}

/// Everything the re-open modal draws, over values rather than over a view model.
struct SequenceProgressPanel: View {
    let progress: SequenceProgress
    let finishProcessing: () -> Void
    let renderVideo: () -> Void
    let dismiss: () -> Void

    /// The same width as `ProcessingModalPanel`, and for the same reason: it holds the
    /// longest translated step name over two lines, and the two panels stack the same rows.
    static var width: CGFloat { ProcessingModalPanel<EmptyView>.width }

    var body: some View {
        ZStack {
            // Dims the window and swallows every click, which is what makes this modal
            // rather than one more panel the user can reach around.
            Rectangle()
              .fill(Color.black.opacity(0.6))
              .contentShape(Rectangle())
              .onTapGesture { }

            VStack(alignment: .leading, spacing: 0) {
                header
                Divider()
                // The plain content first so the panel hugs it, falling through to
                // something that scrolls only on a window too short to hold the rows —
                // a `ScrollView` on its own takes every point it is offered and would
                // leave the content huddled at the top of a full-height panel.
                ViewThatFits(in: .vertical) {
                    content
                    ScrollView { content }
                }
                Divider()
                footer
            }
              // Width fixed, height whatever the content comes to.  No `maxHeight`: that
              // stretches the panel to the height it was offered and leaves the content
              // floating in the middle of it.
              .frame(width: Self.width)
              .background(Color(white: 0.18))
              .cornerRadius(14)
              .shadow(radius: 24)
              .padding(20)
        }
    }

    /// The same rows the processing modal draws, measuring the same steps — but with every
    /// finished frame at the `alreadyDone` end of its bar, since none of this is work that
    /// a run in front of the user did.
    private var content: some View {
        ProcessingStepsView(steps: progress.steps)
          .padding(20)
          .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Which sequence this is, then how far it got — two pairs rather than four evenly
    /// spaced lines, so the caption under each line reads as belonging to it.
    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(localized("ui.where_this_sequence_left_off"))
                  .font(.title2)
                  .foregroundColor(.white)

                // The sequence's own name, because Open Recent is a list of paths and it
                // is entirely possible to have opened the wrong one.
                Text(progress.sequenceName)
                  .font(.caption)
                  .foregroundColor(.gray)
                  .lineLimit(2)
                  .truncationMode(.middle)
                  .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(statusText)
                  .font(.callout)
                  .foregroundColor(progress.isComplete ? .green : .white)
                  .fixedSize(horizontal: false, vertical: true)

                Text(localized("progress.frames_complete",
                               progress.framesComplete,
                               progress.frameCount))
                  .font(.caption)
                  .monospacedDigit()
                  .foregroundColor(.gray)
            }
        }
          .padding(20)
          .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var statusText: String {
        if progress.isComplete {
            localized("ui.processing_complete")
        } else if progress.isUntouched {
            localized("ui.this_sequence_has_not_been_processed_yet")
        } else {
            localized("ui.this_sequence_is_partly_processed")
        }
    }

    /// One action, plus a way out of the panel.  Which action depends on whether there is
    /// anything left to process — offering a render of a sequence with unwritten frames
    /// would offer a video with holes in it.
    private var footer: some View {
        HStack(spacing: 12) {
            Button(localized("ui.close"), action: dismiss)
              .help(localized("ui.close_this_and_go_to_the_frames"))

            Spacer()

            if progress.isComplete {
                Button(localized("ui.render_video"), action: renderVideo)
                  .keyboardShortcut(.defaultAction)
                  .help(localized("ui.render_all_frames_of_this_sequence_with"))
            } else {
                Button(progress.isUntouched
                         ? localized("ui.start_processing")
                         : localized("ui.finish_processing"),
                       action: finishProcessing)
                  .keyboardShortcut(.defaultAction)
                  .help(localized("ui.process_the_frames_that_are_not_finished"))
            }
        }
          .padding(20)
    }
}
