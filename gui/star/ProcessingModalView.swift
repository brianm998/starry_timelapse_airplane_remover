import SwiftUI
import AppKit
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
    @Environment(\.openWindow) private var openWindow

    private var steps: [ProcessingStepProgress] { viewModel.processingSteps }

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
          get: { viewModel.userPreferences.showsAlignmentInProcessingWindow },
          set: { viewModel.userPreferences.showAlignmentInProcessingWindow = $0 }
        )
    }

    /// The concurrency field's own focus scope.  Separate from the right panel's, which is
    /// a different `@FocusState` property in a different view, so both may claim
    /// `.numberOfFramesToProcessConcurrently` without fighting over the keyboard.
    @FocusState private var focusedField: FocusedField?

    /// How fast each step is going, for the estimate in the header: the view model's, which
    /// the menu-bar wand reads too.  `body` also feeds it as it draws, which is harmless
    /// next to the view model's own feed, and not state the view draws, so updating it does
    /// not ask for another pass.
    private var rates: StepRateTracker { viewModel.stepRates }

    /// What star is doing now, across every running step.
    private func headline(for steps: [ProcessingStepProgress]) -> String? {
        return ProcessingHeadline.text(
          steps: steps,
          extraction: viewModel.extractionProgress,
          hasPlan: viewModel.processingHasPlan,
          framesComplete: viewModel.count(for: .complete),
          frameCount: viewModel.frames.count
        )
    }

    var body: some View {
        let steps = self.steps
        // Feed the rates before anything asks them for an estimate.
        let _ = rates.observe(steps)
        let estimates = Dictionary(uniqueKeysWithValues: steps.compactMap { step in
            rates.secondsRemaining(for: step).map { (step.type, $0) }
        })
        ProcessingModalPanel(
          framesComplete: viewModel.count(for: .complete),
          frameCount: viewModel.frames.count,
          steps: steps,
          extraction: viewModel.extractionProgress,
          statusText: viewModel.processingStatusText ?? viewModel.waitingForFramesText,
          headline: headline(for: steps),
          overall: ProcessingHeadline.overallText(steps: steps, secondsRemaining: { rates.secondsRemaining(for: $0) }),
          stepEstimates: estimates,
          showAlignment: showAlignment,
          cameraMoving: viewModel.cameraMotion == .moving,
          openAlignmentWindow: { openWindow(id: StarApp.alignmentWindowName) },
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

    /// One sentence on what is happening right now and why, with a time estimate when one
    /// can be given; drawn directly under the frames-complete line.
    var headline: String? = nil

    /// How long the whole run has left, shown first under the title.
    var overall: String? = nil

    /// Seconds left for each step that has a measured rate, shown beside its bar.
    var stepEstimates: [OperationType: TimeInterval] = [:]

    /// Whether the alignment charts are drawn.  Off is what the toggle in the alignment
    /// heading gives, and it takes the tallest part of the panel with it.
    @Binding var showAlignment: Bool

    /// Whether the camera moved during the sequence; picks the wording of the alignment explanation.
    var cameraMoving: Bool = false

    /// Opens the alignment window; nil leaves the button out.
    var openAlignmentWindow: (() -> Void)? = nil

    /// Whether the explanation of the alignment charts is up over the panel.
    @State private var showingAlignmentInfo = false

    let stop: () -> Void
    let dismiss: () -> Void

    /// How many frames the run may work on at once.  A slot rather than a value for the
    /// same reason `alignmentContent` is one: the editor for it reaches into the
    /// environment for a `ViewModel` (its cursor modifier does), and a panel that needs one
    /// of those is a panel nothing can render on its own.
    @ViewBuilder let concurrencyContent: () -> ConcurrencyContent

    @ViewBuilder let alignmentContent: () -> AlignmentContent

    /// The least the panel is ever wide; a language whose headings or step names need more
    /// makes it wider (see `width(steps:extraction:)`).
    static var minimumWidth: CGFloat { 640 }

    /// What the panel's own padding takes off its width: 20 each side of the steps' list.
    static var contentPadding: CGFloat { 40 }

    /// The panel's width for these rows: 640, or what the columns of the steps' list need in
    /// this language with its padding, whichever is more.  English stays 640.
    static func width(steps: [ProcessingStepProgress], extraction: Bool) -> CGFloat {
        width(for: ProcessingColumns.measured(steps: steps, extraction: extraction))
    }

    static func width(for columns: ProcessingColumns) -> CGFloat {
        max(minimumWidth, columns.required + contentPadding)
    }

    private var panelWidth: CGFloat {
        Self.width(steps: steps, extraction: extraction != nil)
    }

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
              .frame(width: panelWidth)
              .background(Color(white: 0.18))
              .cornerRadius(14)
              .shadow(radius: 24)
              .padding(20)

            if showingAlignmentInfo {
                AlignmentInfoOverlay(cameraMoving: cameraMoving) { showingAlignmentInfo = false }
            }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            ProcessingStepsView(steps: steps, extraction: extraction, estimates: stepEstimates)
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(localized("ui.alignment_2"))
                      .font(.headline)
                      .foregroundColor(.white)
                    AlignmentInfoButton { showingAlignmentInfo = true }
                    if let openAlignmentWindow {
                        Button(action: openAlignmentWindow) {
                            Image(systemName: "arrow.up.forward.app")
                        }
                          .buttonStyle(.borderless)
                          .foregroundColor(.gray)
                          .help(localized("ui.open_alignment_window_help"))
                    }
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
                  .accessibilityIdentifier("processing.modal")
                // The status line wins while there is one: it says what star is doing,
                // where the count would be describing a sequence this run is in the middle
                // of taking apart — "40 / 40 frames complete" over a run that has just
                // started reads as finished.
                Text(statusText ?? localized("progress.frames_complete",
                                             framesComplete, frameCount))
                  .font(.caption)
                  .foregroundColor(.gray)
                if let overall {
                    Text(overall)
                      .font(.caption.weight(.semibold))
                      .foregroundColor(.white)
                      .fixedSize(horizontal: false, vertical: true)
                      .accessibilityIdentifier("processing.overall")
                }
                if let headline {
                    Text(headline)
                      .font(.caption)
                      .foregroundColor(.white.opacity(0.85))
                      .fixedSize(horizontal: false, vertical: true)
                      .accessibilityIdentifier("processing.headline")
                }
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

            HStack(spacing: 12) {
                Text(localized("ui.preview_while_processing_help"))
                  .font(.caption)
                  .foregroundColor(.white)
                  .multilineTextAlignment(.trailing)
                  .fixedSize(horizontal: false, vertical: true)
                  .frame(maxWidth: 320, alignment: .trailing)
                Button(localized("ui.preview"), action: dismiss)
                  .keyboardShortcut(.defaultAction)
                  .help(localized("ui.preview_while_processing_help"))
            }
        }
          .padding(20)
    }
}

/// The widths of the step rows' columns, which every row shares so the numbers line up under
/// their headings.  Each is the constant it always was, or more when a word of its text (a
/// heading, a step name) is wider: a cell narrower than a word breaks the word in two or
/// truncates it with an ellipsis.  The desktop's `ProcessingColumns` is the same.
struct ProcessingColumns: Equatable {
    static let nameWidth: CGFloat = 180
    static let numberWidth: CGFloat = 46
    /// The time-left column between each bar and its counts.
    static let etaWidth: CGFloat = 56
    static let rowGap: CGFloat = 12
    /// The bar is the cell that gives way, but not below this.
    static let minimumBarWidth: CGFloat = 80

    let name: CGFloat
    let number: CGFloat
    let eta: CGFloat

    /// The three number columns together: also the width of the "n of m complete" count.
    var count: CGFloat { number * 3 }

    /// Every column and the gaps between them (name, bar, time left, counts), with the bar at its least.
    var required: CGFloat { name + eta + count + Self.rowGap * 3 + Self.minimumBarWidth }

    static func measured(steps: [ProcessingStepProgress], extraction: Bool) -> ProcessingColumns {
        measured(stepNames: steps.map { $0.type.stepName }, extraction: extraction)
    }

    static func measured(stepNames: [String], extraction: Bool) -> ProcessingColumns {
        let caption = NSFont.monospacedDigitSystemFont(
          ofSize: NSFont.preferredFont(forTextStyle: .caption1).pointSize, weight: .regular)
        let callout = NSFont.preferredFont(forTextStyle: .callout)
        let headings = TextFit.widestWord(
          [localized("ui.queued"), localized("ui.running"), localized("ui.done")], font: caption)
        // The count under the extraction row is three number columns wide, so the widest
        // word of "n of m complete" sets a third of it.
        let ofM = TextFit.widestWord([localized("ui.n_of_m_complete", 99999, 99999)], font: caption)
        // The heading may wrap at its space; an estimate is one line, as long as the longest
        // the column shows ("9 h 59 min").
        let eta = max(
          TextFit.widestWord([localized("ui.time_left")], font: caption),
          TextFit.widestWord([ProcessingHeadline.duration(9 * 3600 + 59 * 60)], font: caption, wholeText: true))
        let names = TextFit.widestWord(
          stepNames + (extraction ? [localized("ui.processing_step_extracting_video")] : []), font: callout)
        return ProcessingColumns(
          name: max(nameWidth, names),
          number: max(numberWidth, headings, ofM / 3),
          eta: max(etaWidth, eta))
    }
}

/// Measuring translated text, to size a column from what it will hold.
enum TextFit {
    /// Room beyond the measured width, for the rounding between measuring and drawing.
    static let slack: CGFloat = 1

    /// The width of the widest word of `texts` (split at spaces and line breaks) in `font`, or
    /// of the widest whole text with `wholeText`.
    static func widestWord(_ texts: [String], font: NSFont, wholeText: Bool = false) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        func width(_ text: String) -> CGFloat {
            (text as NSString).size(withAttributes: attributes).width
        }
        let pieces = wholeText ? texts : texts.flatMap { $0.split(whereSeparator: { $0 == " " || $0.isNewline }).map(String.init) }
        return (pieces.map(width).max() ?? 0).rounded(.up) + slack
    }
}

/// One bar per processing step, stacked in the order `ProcessingSteps.types` gives them.
struct ProcessingStepsView: View {
    let steps: [ProcessingStepProgress]
    /// The video extraction, shown as the first row, above the horizon; nil for frames that are not being extracted from a video.
    var extraction: FrameExtractionProgress? = nil
    /// Seconds left per step, for the column beside the bars.
    var estimates: [OperationType: TimeInterval] = [:]

    private let doneColor: Color = .green
    private let runningColor: Color = .yellow
    private let queuedColor = Color(white: 0.32)
    /// For what is finished, or has nothing left: quieter than the white of what is live.
    private let settledColor = Color(white: 0.68)

    /// Wide enough for the widest word of every translated heading and step name at its
    /// font, shared by every row: the constants of `ProcessingColumns`, or more.
    private var columns: ProcessingColumns {
        ProcessingColumns.measured(steps: steps, extraction: extraction != nil)
    }

    private func etaText(_ seconds: TimeInterval?) -> String {
        guard let seconds, seconds.isFinite else { return "" }
        return ProcessingHeadline.duration(seconds)
    }

    private func etaColumn(_ text: String, color: Color = .white, columns: ProcessingColumns) -> some View {
        // A heading wraps at its space; an estimate is one line and the column is as wide as
        // the longest one.
        Text(text)
          .font(.caption)
          .monospacedDigit()
          .foregroundColor(color)
          .lineLimit(2)
          .multilineTextAlignment(.trailing)
          .fixedSize(horizontal: false, vertical: true)
          .frame(width: columns.eta, alignment: .trailing)
    }

    /// Steps with something to count and nothing left queued or running.  A step with no
    /// operations yet is still being planned, which is not done.
    private var doneSteps: [ProcessingStepProgress] {
        steps.filter { $0.hasWork && $0.queued == 0 && $0.running == 0 }
    }

    private var processingSteps: [ProcessingStepProgress] {
        steps.filter { !($0.hasWork && $0.queued == 0 && $0.running == 0) }
    }

    var body: some View {
        let columns = self.columns
        VStack(alignment: .leading, spacing: 8) {
            Text(localized("ui.steps"))
              .font(.headline)
              .foregroundColor(.white)

            if let extraction {
                extractionRow(extraction, columns: columns)
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
                columnHeader(localized("ui.done"), showsCounts: true, columns: columns)
                ForEach(doneSteps) { step in
                    stepRow(step, isDone: true, columns: columns)
                }
            }
            if !processingSteps.isEmpty {
                columnHeader(localized("ui.processing"), showsCounts: doneSteps.isEmpty, columns: columns)
                ForEach(processingSteps) { step in
                    stepRow(step, isDone: false, columns: columns)
                }
            }
        }
    }

    /// A sub-label over a group of rows.  The first one on screen also carries the names of
    /// the three number columns, which line up with every row beneath it.
    private func columnHeader(_ title: String, showsCounts: Bool, columns: ProcessingColumns) -> some View {
        HStack(spacing: 12) {
            Text(title)
              .font(.subheadline)
              .foregroundColor(.gray)
              .frame(width: columns.name, alignment: .leading)
            Spacer()
            if showsCounts {
                etaColumn(localized("ui.time_left"), color: .gray, columns: columns)
                countColumns(localized("ui.queued"), localized("ui.running"), localized("ui.done"),
                             colors: [.gray, .gray, .gray], columns: columns)
            }
        }
          .padding(.top, 4)
    }

    private func countColumns(_ queued: String, _ running: String, _ done: String,
                              colors: [Color], columns: ProcessingColumns) -> some View {
        HStack(spacing: 0) {
            ForEach(Array([queued, running, done].enumerated()), id: \.offset) { index, text in
                Text(text)
                  .font(.caption)
                  .monospacedDigit()
                  .foregroundColor(colors[index])
                  .lineLimit(2)
                  .multilineTextAlignment(.trailing)
                  .fixedSize(horizontal: false, vertical: true)
                  .frame(width: columns.number, alignment: .trailing)
            }
        }
    }

    /// The frames the video has given up so far, in the same bar and count as the steps below.
    private func extractionRow(_ progress: FrameExtractionProgress, columns: ProcessingColumns) -> some View {
        let total = max(1, progress.total)
        let name = localized("ui.processing_step_extracting_video")
        return HStack(spacing: 12) {
            Text(name)
              .font(.callout)
              .foregroundColor(.white)
              .lineLimit(2)
              .fixedSize(horizontal: false, vertical: true)
              .frame(width: columns.name, alignment: .leading)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Rectangle().fill(queuedColor)
                    Rectangle().fill(doneColor)
                      .frame(width: geometry.size.width * CGFloat(progress.extracted) / CGFloat(total))
                }
                  .cornerRadius(4)
            }
              .frame(height: 14)
            etaColumn(progress.isComplete ? "" : etaText(progress.estimatedSecondsRemaining), columns: columns)
            Text(localized("ui.n_of_m_complete", progress.extracted, progress.total))
              .font(.caption)
              .monospacedDigit()
              .foregroundColor(.white)
              .lineLimit(2)
              .fixedSize(horizontal: false, vertical: true)
              .frame(width: columns.count, alignment: .trailing)
        }
          .contentShape(Rectangle())
          .help(name)
          .accessibilityIdentifier("processing.extraction")
    }

    private func stepRow(_ step: ProcessingStepProgress, isDone: Bool, columns: ProcessingColumns) -> some View {
        HStack(spacing: 12) {
            // Two lines because these are translated, and no single-line column this
            // panel can afford would hold every language's version of every name.
            Text(step.type.stepName)
              .font(.callout)
              .foregroundColor(!step.hasWork ? .gray : isDone ? settledColor : .white)
              .lineLimit(2)
              .fixedSize(horizontal: false, vertical: true)
              .frame(width: columns.name, alignment: .leading)

            stepBar(step)

            etaColumn(isDone ? "" : etaText(estimates[step.type]), columns: columns)

            // A step with no operations is only ever on screen while the plan is still
            // being worked out — once it is, `ProcessingSteps.visible` drops it — so this
            // says "not known yet", which no wording says as plainly as leaving it out.
            if step.hasWork {
                // A column goes quiet when it has nothing to say: nothing queued, nothing
                // running, or everything done.
                let total = step.queued + step.running + step.completed
                countColumns("\(step.queued)", "\(step.running)", "\(step.completed)",
                             colors: [step.queued == 0 ? settledColor : .white,
                                      step.running == 0 ? settledColor : .white,
                                      step.completed == total ? settledColor : .white],
                             columns: columns)
            } else {
                Text("—")
                  .font(.caption)
                  .foregroundColor(.gray)
                  .frame(width: columns.count, alignment: .trailing)
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
