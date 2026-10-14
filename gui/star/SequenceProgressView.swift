import SwiftUI
import StarCore
import logging

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
    static var width: CGFloat { ProcessingModalPanel<EmptyView, EmptyView>.width }

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
