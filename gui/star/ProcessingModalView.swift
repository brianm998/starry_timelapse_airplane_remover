import SwiftUI
import StarCore
import logging

/// How far along one processing step is, over the whole of what that step has to cover.
///
/// The three live counts are operations rather than frames, because that is what there is
/// to count: `FrameGraphBuilder` builds one op per frame for most steps, but it skips the
/// frames whose artifact is already on disk, and the static tripod case merges every
/// horizon in a single op.  Measuring a bar on those alone measures the wrong job the
/// moment a run is resumed — a sequence half written builds ops for the half that is left,
/// and a bar over them starts at zero as though nothing had ever been done.  `alreadyDone`
/// is the rest of it, reported by the builder, and it belongs at the finished end.
struct ProcessingStepProgress: Identifiable, Equatable {
    let type: OperationType
    let queued: Int
    let running: Int
    let done: Int

    /// Frames of this step that were finished before the run started, so the graph built
    /// no operation for them.  Part of the bar, at the done end: a sequence resumed half
    /// way through is half finished, not starting from nothing.
    let alreadyDone: Int

    init(type: OperationType, queued: Int, running: Int, done: Int, alreadyDone: Int = 0) {
        self.type = type
        self.queued = queued
        self.running = running
        self.done = done
        self.alreadyDone = alreadyDone
    }

    var id: OperationType { type }

    /// Every frame this step covers, whoever did it and whenever.
    var total: Int { alreadyDone + queued + running + done }

    /// Frames of this step that are finished, this run's and any earlier run's alike.
    var completed: Int { alreadyDone + done }

    /// A step with nothing to it at all: no operations, and nothing already on disk that
    /// they would have produced.  Not a step this run is taking in any sense.
    var hasWork: Bool { total > 0 }

    var doneFraction: Double { fraction(of: completed) }
    var runningFraction: Double { fraction(of: running) }

    private func fraction(of count: Int) -> Double {
        total > 0 ? Double(count) / Double(total) : 0
    }
}

/// The steps the processing modal draws, and how it reads their progress out of
/// `FrameGraphViewModel`.
///
/// Plain functions over plain values rather than anything the view owns, so the arithmetic
/// below — which is the part that can be wrong without looking wrong — is testable.
enum ProcessingSteps {

    /// The steps this configuration will take, in the order the modal stacks them: horizon
    /// work first, then keypoints, then alignment, then outlier detection, then the merge
    /// that consumes all of it.
    ///
    /// The conditions are `FrameGraphBuilder.build`'s own, spelled the same way, because a
    /// row for a step that will never run is worse than no row: it sits at zero for the
    /// whole run and reads as something stuck.  Two of them are easy to get wrong from the
    /// gui side — earth work needs the camera to have been moving as well as the setting to
    /// be on, since a fixed tripod has nothing to align the ground against, and a painted
    /// static reference horizon replaces horizon detection and its merge outright.
    ///
    /// Deliberately not `OperationType.allCases`: `preview` is thumbnail work that has
    /// nothing to do with a processing run, and `alignmentValidation` is an internal stage
    /// this display does not break out.
    static func types(
      horizonDetectionEnabled: Bool,
      hasStaticReferenceHorizon: Bool,
      cameraWasMoving: Bool,
      allowEarthAlignment: Bool,
      usesOutliers: Bool
    ) -> [OperationType] {
        let paintedStaticReference = hasStaticReferenceHorizon && !cameraWasMoving
        let detectsHorizons = horizonDetectionEnabled && !paintedStaticReference
        let processesEarth = horizonDetectionEnabled && allowEarthAlignment && cameraWasMoving

        var types: [OperationType] = []
        if detectsHorizons {
            types.append(.horizon)
            types.append(.mergedHorizon)
        }
        types.append(.starKeypoints)
        if processesEarth { types.append(.earthKeypoints) }
        types.append(.starHomography)
        if processesEarth { types.append(.earthHomography) }
        if usesOutliers { types.append(.outliers) }
        types.append(.merge)
        return types
    }

    /// The steps a run under `config` will take.
    static func types(for config: Config) -> [OperationType] {
        types(horizonDetectionEnabled: config.horizonDetectionEnabled,
              hasStaticReferenceHorizon: config.hasStaticReferenceHorizon,
              cameraWasMoving: config.tripodHeadWasMoving,
              allowEarthAlignment: config.allowEarthAlignment,
              usesOutliers: config.cleanMethod.usesOutliers)
    }

    /// The rows worth drawing, out of the steps this configuration can take.
    ///
    /// A step can be one this run does not need even though the configuration allows it —
    /// every artifact it would produce is already on disk, so the builder gives it no
    /// operations at all.  Those are dropped, but only once `graphIsBuilt`: while the plan
    /// is still being assembled every step has no operations yet, and filtering then would
    /// empty the panel and then pop the rows in one at a time as the builder reached them.
    static func visible(
      _ steps: [ProcessingStepProgress],
      graphIsBuilt: Bool
    ) -> [ProcessingStepProgress] {
        graphIsBuilt ? steps.filter(\.hasWork) : steps
    }

    /// Progress for each of `types`, measured from `baseline`.
    ///
    /// `FrameGraphViewModel`'s counters only reset when the sequence is closed, so by the
    /// second run of a session they already hold every op the first run finished.  Taking a
    /// baseline when a run starts is what keeps the bars showing *this* run rather than
    /// filling in most of the way the moment they appear.
    ///
    /// The counters move a count between states rather than recounting, so `queued +
    /// running + done` for a type only ever grows: subtracting the baseline from it gives
    /// the ops this run created.  The clamping below matters only if a previous run's ops
    /// were still in flight when this one started, which the gui does not allow — it is
    /// there so that case reads as odd numbers rather than as a negative width.
    static func progress(
      for types: [OperationType],
      counts: [OperationType: [OperationState: UInt]],
      since baseline: [OperationType: [OperationState: UInt]] = [:],
      alreadyDone: [OperationType: UInt] = [:]
    ) -> [ProcessingStepProgress] {
        types.map { type in
            let now = counts[type] ?? [:]
            let base = baseline[type] ?? [:]

            func count(_ states: [OperationState: UInt], _ state: OperationState) -> Int {
                Int(states[state] ?? 0)
            }
            func total(_ states: [OperationState: UInt]) -> Int {
                count(states, .queued) + count(states, .running) + count(states, .done)
            }

            let created = max(0, total(now) - total(base))
            let done = max(0, count(now, .done) - count(base, .done))
            let running = min(count(now, .running), created)
            let all = max(created, done + running)

            return ProcessingStepProgress(
              type: type,
              queued: max(0, all - done - running),
              running: running,
              done: min(done, all),
              alreadyDone: Int(alreadyDone[type] ?? 0)
            )
        }
    }
}

extension OperationType {
    /// What the processing modal labels this step.
    ///
    /// A noun, unlike `UpdatableProgressMonitor`'s `logName`, which is the tail of a cli
    /// progress bar caption ("found horizon") and reads wrong as a row label.  The types
    /// the modal never lists fall back to the raw name; nothing shows those.
    var stepName: String {
        switch self {
        case .horizon:         localized("ui.horizon")
        case .mergedHorizon:   localized("ui.merged_horizon")
        case .starKeypoints:   localized("ui.star_keypoints")
        case .earthKeypoints:  localized("ui.earth_keypoints")
        case .starHomography:  localized("ui.star_alignment")
        case .earthHomography: localized("ui.earth_alignment")
        case .outliers:        localized("ui.outliers")
        case .merge:           localized("ui.merged")
        default:               rawValue
        }
    }

    /// What this step does, how long it tends to take, and why — the tooltip on its row.
    ///
    /// The cost each one describes is not a guess: every op reserves against a multiple of
    /// the working frame recorded in `Config`, and those properties carry the measurements
    /// the wording here is drawn from — `keypointMemoryMultiplier` for why detection is the
    /// step that sets the pace, `horizonMemoryMultiplier` and `horizonReservationFloorMB`
    /// for why horizon detection is nearly flat in frame size, `outlierMemoryMultiplier`
    /// for why outlier cost follows how much is in the frame rather than how big it is.
    /// Check them there if any of this stops being true.
    var stepHelp: String {
        switch self {
        case .horizon:         localized("ui.step_help.horizon")
        case .mergedHorizon:   localized("ui.step_help.merged_horizon")
        case .starKeypoints:   localized("ui.step_help.star_keypoints")
        case .earthKeypoints:  localized("ui.step_help.earth_keypoints")
        case .starHomography:  localized("ui.step_help.star_alignment")
        case .earthHomography: localized("ui.step_help.earth_alignment")
        case .outliers:        localized("ui.step_help.outliers")
        case .merge:           localized("ui.step_help.merged")
        default:               ""
        }
    }
}

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
          showAlignment: showAlignment,
          stop: { viewModel.stopProcessing() },
          dismiss: { viewModel.processingModalShowing = false },
          concurrencyContent: {
              // The same control the right panel carries, which this modal covers up while
              // it is on screen.  Editing it while a run is going is the point: a changed
              // config goes through `ConfigManager.onUpdate` to
              // `FrameGraphBuilder.update(from:)`, which sets the operation queue's
              // `maxConcurrentOperationCount` there and then.
              EditableNumberOfFramesToProcessConcurrentlyView(
                focusedField: $focusedField,
                textColor: .gray,
                alwaysOpen: false
              )
                .font(.caption)
                .help(localized("ui.number_of_frames_to_process_concurrently_help"))
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
            ProcessingStepsView(steps: steps)
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
                Text(localized("progress.frames_complete", framesComplete, frameCount))
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

            Button(localized("ui.dismiss"), action: dismiss)
              .keyboardShortcut(.defaultAction)
              .help(localized("ui.keep_processing_and_go_back_to_the_frames"))
        }
          .padding(20)
    }
}

/// One bar per processing step, stacked in the order `ProcessingSteps.types` gives them.
struct ProcessingStepsView: View {
    let steps: [ProcessingStepProgress]

    private let doneColor: Color = .green
    private let runningColor: Color = .yellow
    private let queuedColor = Color(white: 0.32)

    /// Wide enough for the longest translated step name at this font — "Zusammengeführter
    /// Horizont" in German — over two lines.
    private let labelWidth: CGFloat = 180
    private let countWidth: CGFloat = 140

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(localized("ui.processing_steps"))
              .font(.headline)
              .foregroundColor(.white)

            if steps.isEmpty {
                // Every step this configuration takes turned out to have nothing left to
                // do — a re-run over a sequence that is already finished.  Rare, and over
                // quickly, but a lone heading with nothing under it looks broken.
                Text(localized("ui.nothing_to_do"))
                  .foregroundColor(.gray)
            }

            ForEach(steps) { step in
                stepRow(step)
            }
        }
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
            Text(step.hasWork
                   ? localized("ui.n_of_m_complete", step.completed, step.total)
                   : "—")
              .font(.caption)
              .monospacedDigit()
              .foregroundColor(step.hasWork ? .white : .gray)
              // Wraps rather than shrinking.  `minimumScaleFactor` was scaling one row and
              // not the row above it with the very same text in it — measured — which
              // reads as a rendering fault; wrapping is at least the same on every row.
              .lineLimit(2)
              .fixedSize(horizontal: false, vertical: true)
              .frame(width: countWidth, alignment: .trailing)
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
