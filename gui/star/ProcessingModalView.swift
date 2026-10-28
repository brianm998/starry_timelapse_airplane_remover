import SwiftUI
import StarCore
import logging

/// The modal star puts up while it is processing frames: what each step is doing, and how
/// well the frames are lining up, without the user having to know that the left panel
/// exists or what its columns of numbers mean.
///
/// Dismissing it leaves the run going and hands the window back, so the user can look
/// through frames that are already done; the left panel and everything else are exactly as
/// they were.  Stopping it stops the run, the same way the Stop button under the frame
/// does.
///
/// Presented as an `.overlay` rather than as a member of a `ZStack` or as a `.sheet`: an
/// overlay is sized by what it is attached to and reports nothing back, so this panel can
/// never become part of the window's minimum size — the mistake that once let a hand-drawn
/// alert grow the main window to 1452x3104 (see the note in `ContentView`).
///
/// This is only the wiring: everything drawn lives in `ProcessingModalPanel`, which takes
/// values rather than reading the view model, and so can be rendered — and looked at — on
/// its own.
struct ProcessingModalView: View {
    @Environment(ImageSequenceViewModel.self) var viewModel: ImageSequenceViewModel
    @Environment(FrameGraphViewModel.self) var frameGraphViewModel: FrameGraphViewModel

    private var steps: [ProcessingStepProgress] {
        // `alreadyDone` describes whichever graph was built last, so until this run's is
        // the one that was, it is the previous run's answer and belongs to nobody.  The
        // same number gates the filtering below for the same reason.
        let graphIsBuilt = frameGraphViewModel.graphBuildsCompleted
                             > viewModel.processingBuildCount
        return ProcessingSteps.visible(
          ProcessingSteps.progress(
            for: viewModel.processingStepTypes,
            counts: frameGraphViewModel.operations,
            since: viewModel.processingStepBaseline,
            alreadyDone: graphIsBuilt ? frameGraphViewModel.alreadyDone : [:]
          ),
          graphIsBuilt: graphIsBuilt
        )
    }

    private var hasStarAlignmentData: Bool {
        viewModel.starAlignmentInfo.contains { !$0.isEmpty }
    }

    private var hasEarthAlignmentData: Bool {
        viewModel.earthAlignmentInfo.contains { !$0.isEmpty }
    }

    /// Whether the charts are drawn, kept in preferences rather than in this view's state:
    /// the view is rebuilt every time the modal is dismissed and brought back.
    private var showAlignment: Binding<Bool> {
        Binding(
          get: { viewModel.userPreferences.showAlignmentInProcessingWindow ?? true },
          set: { viewModel.userPreferences.showAlignmentInProcessingWindow = $0 }
        )
    }

    /// The concurrency field's own focus scope.  Separate from the right panel's, which is
    /// a different `@FocusState` property in a different view, so both may claim
    /// `.numberOfFramesToProcessConcurrently` without fighting over the keyboard.
    @FocusState private var focusedField: FocusedField?

    var body: some View {
        ProcessingModalPanel(
          framesComplete: viewModel.count(for: .complete),
          frameCount: viewModel.frames.count,
          steps: steps,
          extraction: viewModel.extractionProgress,
          statusText: viewModel.processingStatusText ?? viewModel.waitingForFramesText,
          showAlignment: showAlignment,
          stop: { viewModel.stopProcessing() },
          dismiss: { viewModel.processingModalShowing = false },
          concurrencyContent: {
              // The same control the right panel carries, which this modal covers up while
              // it is on screen.  Editing it while a run is going is the point: a changed
              // config goes through `ConfigManager.onUpdate` to
              // `FrameGraphBuilder.update(from:)`, which moves every gate, the memory budget
              // and the operation queue's width there and then.
              ResourceProfileView(textColor: .gray)
                .font(.caption)
          }
        ) {
            alignmentCharts
        }
    }

    /// The same deviation chart the left panel and the alignment window draw, at a size
    /// worth looking at.  Earth only when this sequence aligns the earth at all.
    @ViewBuilder
    private var alignmentCharts: some View {
        if hasStarAlignmentData {
            Text(localized("ui.deviation_in_star_alignment"))
              .font(.caption)
              .foregroundColor(.gray)
            AlignmentDeviationChart(
              frames: viewModel.starAlignmentInfo,
              foregroundColor: .white
            )
              .frame(height: 220)

            if viewModel.allowEarthAlignment,
               hasEarthAlignmentData
            {
                Text(localized("ui.deviation_in_earth_alignment"))
                  .font(.caption)
                  .foregroundColor(.gray)
                AlignmentDeviationChart(
                  frames: viewModel.earthAlignmentInfo,
                  foregroundColor: .white
                )
                  .frame(height: 220)
            }
        } else {
            // Nothing has aligned yet.  An empty chart here reads as a failure rather than
            // as a step that has not run, so say which it is — in the space the chart will
            // take, so the panel does not jump when the first result lands.
            Text(localized("ui.waiting_for_alignment_data"))
              .foregroundColor(.gray)
              .frame(maxWidth: .infinity)
              .frame(height: 220)
        }
    }
}

/// Everything the processing modal draws, over values rather than over a view model.
///
/// Split out so the layout can be rendered without a loaded image sequence behind it —
/// these are the numbers and the translated labels that decide whether a row fits.
struct ProcessingModalPanel<AlignmentContent: View, ConcurrencyContent: View>: View {
    let framesComplete: Int
    let frameCount: Int
    let steps: [ProcessingStepProgress]

    /// How far extracting the video's frames has got; nil when the frames did not come from a video being extracted,
    /// which is when the extraction row is not shown.
    var extraction: FrameExtractionProgress? = nil

    /// What the run is doing, for a run that cannot yet be counted in operations — shown
    /// under the title in place of the frames-complete line.  Normally `nil`: a run that
    /// builds a frame graph has operations to count from the start, and the frames-complete
    /// line is the more useful of the two.
    var statusText: String? = nil

    /// Whether the alignment charts are drawn.  Off is what the toggle in the alignment
    /// heading gives, and it takes the tallest part of the panel with it.
    @Binding var showAlignment: Bool

    let stop: () -> Void
    let dismiss: () -> Void

    /// How many frames the run may work on at once.  A slot rather than a value for the
    /// same reason `alignmentContent` is one: the editor for it reaches into the
    /// environment for a `ViewModel` (its cursor modifier does), and a panel that needs one
    /// of those is a panel nothing can render on its own.
    @ViewBuilder let concurrencyContent: () -> ConcurrencyContent

    @ViewBuilder let alignmentContent: () -> AlignmentContent

    static var width: CGFloat { 640 }

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
                // A `ScrollView` takes every point it is offered, which would leave the
                // panel the full height of the window with the content huddled at the top.
                // Offering the plain content first lets the panel hug it, and only the
                // sequences big enough to overflow — two alignment charts on a short
                // window — fall through to something that scrolls.
                ViewThatFits(in: .vertical) {
                    content
                    ScrollView { content }
                }
                Divider()
                footer
            }
              // Width is fixed; height is whatever the content comes to.  No `maxHeight`,
              // which would stretch the panel to the height it was offered and leave the
              // content floating in the middle of it — the cap on a tall run is the
              // `ScrollView` that `ViewThatFits` falls through to.
              .frame(width: Self.width)
              .background(Color(white: 0.18))
              .cornerRadius(14)
              .shadow(radius: 24)
              .padding(20)
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            ProcessingStepsView(steps: steps, extraction: extraction)
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(localized("ui.alignment_2"))
                      .font(.headline)
                      .foregroundColor(.white)
                    Spacer()
                    Toggle(localized("ui.show_alignment_results"), isOn: $showAlignment)
                      .toggleStyle(.checkbox)
                      .font(.caption)
                      .foregroundColor(.gray)
                      .help(localized("ui.show_alignment_results_help"))
                }
                if showAlignment {
                    alignmentContent()
                }
            }
        }
          .padding(20)
          .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        HStack(spacing: 12) {
            ProgressView()
              .colorScheme(.dark)
              .scaleEffect(0.7)
              .frame(width: 20, height: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(localized("ui.processing_frames"))
                  .font(.title2)
                  .foregroundColor(.white)
                // The status line wins while there is one: it says what star is doing,
                // where the count would be describing a sequence this run is in the middle
                // of taking apart — "40 / 40 frames complete" over a run that has just
                // started reads as finished.
                Text(statusText ?? localized("progress.frames_complete",
                                             framesComplete, frameCount))
                  .font(.caption)
                  .foregroundColor(.gray)
            }
            Spacer()
            concurrencyContent()
        }
          .padding(20)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button(action: stop) {
                Text(localized("ui.stop_processing"))
                  .foregroundColor(.white)
                  .padding(.horizontal, 10)
                  .padding(.vertical, 5)
                  .background(Color.red.opacity(0.8))
                  .cornerRadius(6)
            }
              .buttonStyle(PlainButtonStyle())
              .help(localized("ui.cancel_all_pending_processing_operations"))

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Button(localized("ui.preview"), action: dismiss)
                  .keyboardShortcut(.defaultAction)
                  .help(localized("ui.preview_while_processing_help"))
                Text(localized("ui.preview_while_processing_help"))
                  .font(.caption)
                  .foregroundColor(.secondary)
                  .multilineTextAlignment(.trailing)
                  .fixedSize(horizontal: false, vertical: true)
                  .frame(maxWidth: 320, alignment: .trailing)
            }
        }
          .padding(20)
    }
}

/// One bar per processing step, stacked in the order `ProcessingSteps.types` gives them.
struct ProcessingStepsView: View {
    let steps: [ProcessingStepProgress]
    /// The video extraction, shown as the first row, above the horizon; nil for frames that are not being extracted from a video.
    var extraction: FrameExtractionProgress? = nil

    private let doneColor: Color = .green
    private let runningColor: Color = .yellow
    private let queuedColor = Color(white: 0.32)

    /// Wide enough for the longest translated step name at this font — "Zusammengeführter
    /// Horizont" in German — over two lines.
    private let labelWidth: CGFloat = 180
    private let countWidth: CGFloat = 138
    /// One of the three queued / running / done number columns.
    private let numberWidth: CGFloat = 46

    /// Steps with something to count and nothing left queued or running.  A step with no
    /// operations yet is still being planned, which is not done.
    private var doneSteps: [ProcessingStepProgress] {
        steps.filter { $0.hasWork && $0.queued == 0 && $0.running == 0 }
    }

    private var processingSteps: [ProcessingStepProgress] {
        steps.filter { !($0.hasWork && $0.queued == 0 && $0.running == 0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(localized("ui.steps"))
              .font(.headline)
              .foregroundColor(.white)

            if let extraction {
                extractionRow(extraction)
            }

            if steps.isEmpty && extraction == nil {
                // Every step this configuration takes turned out to have nothing left to
                // do — a re-run over a sequence that is already finished.  Rare, and over
                // quickly, but a lone heading with nothing under it looks broken.
                Text(localized("ui.nothing_to_do"))
                  .foregroundColor(.gray)
            }

            // Done above, Processing beneath it.  Each heading is there only while it has
            // rows, so a finishing step moves from one list to the other, bringing the Done
            // heading with it the first time and taking the Processing one away the last.
            if !doneSteps.isEmpty {
                columnHeader(localized("ui.done"), showsCounts: true)
                ForEach(doneSteps) { step in
                    stepRow(step)
                }
            }
            if !processingSteps.isEmpty {
                columnHeader(localized("ui.processing"), showsCounts: doneSteps.isEmpty)
                ForEach(processingSteps) { step in
                    stepRow(step)
                }
            }
        }
    }

    /// A sub-label over a group of rows.  The first one on screen also carries the names of
    /// the three number columns, which line up with every row beneath it.
    private func columnHeader(_ title: String, showsCounts: Bool) -> some View {
        HStack(spacing: 12) {
            Text(title)
              .font(.subheadline)
              .foregroundColor(.gray)
              .frame(width: labelWidth, alignment: .leading)
            Spacer()
            if showsCounts {
                countColumns(localized("ui.queued"), localized("ui.running"), localized("ui.done"),
                             color: .gray)
            }
        }
          .padding(.top, 4)
    }

    private func countColumns(_ queued: String, _ running: String, _ done: String,
                              color: Color) -> some View {
        HStack(spacing: 0) {
            ForEach([queued, running, done], id: \.self) { text in
                Text(text)
                  .font(.caption)
                  .monospacedDigit()
                  .foregroundColor(color)
                  .lineLimit(1)
                  .frame(width: numberWidth, alignment: .trailing)
            }
        }
    }

    /// The frames the video has given up so far, in the same bar and count as the steps below.
    private func extractionRow(_ progress: FrameExtractionProgress) -> some View {
        let total = max(1, progress.total)
        let name = localized("ui.processing_step_extracting_video")
        return HStack(spacing: 12) {
            Text(name)
              .font(.callout)
              .foregroundColor(.white)
              .lineLimit(2)
              .fixedSize(horizontal: false, vertical: true)
              .frame(width: labelWidth, alignment: .leading)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Rectangle().fill(queuedColor)
                    Rectangle().fill(doneColor)
                      .frame(width: geometry.size.width * CGFloat(progress.extracted) / CGFloat(total))
                }
                  .cornerRadius(4)
            }
              .frame(height: 14)
            Text(localized("ui.n_of_m_complete", progress.extracted, progress.total))
              .font(.caption)
              .monospacedDigit()
              .foregroundColor(.white)
              .lineLimit(2)
              .fixedSize(horizontal: false, vertical: true)
              .frame(width: countWidth, alignment: .trailing)
        }
          .contentShape(Rectangle())
          .help(name)
          .accessibilityIdentifier("processing.extraction")
    }

    private func stepRow(_ step: ProcessingStepProgress) -> some View {
        HStack(spacing: 12) {
            // Two lines because these are translated, and no single-line column this
            // panel can afford would hold every language's version of every name.
            Text(step.type.stepName)
              .font(.callout)
              .foregroundColor(step.hasWork ? .white : .gray)
              .lineLimit(2)
              .fixedSize(horizontal: false, vertical: true)
              .frame(width: labelWidth, alignment: .leading)

            stepBar(step)

            // A step with no operations is only ever on screen while the plan is still
            // being worked out — once it is, `ProcessingSteps.visible` drops it — so this
            // says "not known yet", which no wording says as plainly as leaving it out.
            if step.hasWork {
                countColumns("\(step.queued)", "\(step.running)", "\(step.completed)",
                             color: .white)
            } else {
                Text("—")
                  .font(.caption)
                  .foregroundColor(.gray)
                  .frame(width: numberWidth * 3, alignment: .trailing)
            }
        }
          // Over the whole row, gaps included, rather than over the label alone: the bar
          // is the part of the row the eye is on, and it is the part being explained.
          .contentShape(Rectangle())
          .help(helpText(for: step))
    }

    /// The name first, because the label beside a long translated name may be truncated,
    /// and then what the step is and what it costs.
    private func helpText(for step: ProcessingStepProgress) -> String {
        let help = step.type.stepHelp
        return help.isEmpty ? step.type.stepName : "\(step.type.stepName)\n\n\(help)"
    }

    /// Done, then running, then whatever is still queued as the track behind them — the
    /// same three colours the left panel's frame progress bar uses for the same three
    /// meanings.
    private func stepBar(_ step: ProcessingStepProgress) -> some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                Rectangle()
                  .fill(queuedColor)
                HStack(spacing: 0) {
                    Rectangle()
                      .fill(doneColor)
                      .frame(width: width * step.doneFraction)
                    Rectangle()
                      .fill(runningColor)
                      .frame(width: width * step.runningFraction)
                }
            }
              .cornerRadius(4)
        }
          .frame(height: 14)
    }
}
