import SwiftUI
import StarCore

/// What the menu-bar wand says about the run in progress, as plain values.
///
/// It exists so the wording and the numbers can be tested without a window or a running
/// sequence.  Nothing here measures progress: the stage line and the time left are the ones
/// `ProcessingHeadline` gives the processing modal, the steps are the modal's
/// (`ImageSequenceViewModel.processingSteps`), and the frame count is the one under the
/// modal's title.
enum MenuBarStatus: Equatable {

    /// A processing run, as the modal shows it.
    struct Run: Equatable {
        /// The sequence's folder name.
        var sequenceName: String
        /// What star is doing now (`ProcessingHeadline.text`); nil when it has nothing to say yet.
        var stage: String?
        var framesDone: Int
        var frameCount: Int
        /// framesDone / frameCount, 0 for a sequence with no frames: the overall bar.
        var fraction: Double
        /// "About 4 min left overall" (`ProcessingHeadline.overallText`); nil until a rate is known.
        var overall: String?
    }

    case idle
    case processing(Run)
    /// Rendering the video, with how far ffmpeg has got (0...1).
    case rendering(fraction: Double)

    /// - Parameters:
    ///   - sequenceName: nil when no sequence is open, which is idle whatever the flags say.
    ///   - steps: the visible steps, as `ImageSequenceViewModel.processingSteps` gives them.
    ///   - hasPlan: whether this run's operations have been built.
    ///   - statusText: what the run is doing before it has operations, said in place of a stage.
    ///   - secondsRemaining: per-step time left, from the same `StepRateTracker` the modal reads.
    static func make(
      sequenceName: String?,
      isProcessing: Bool,
      isRendering: Bool,
      renderFraction: Double,
      steps: [ProcessingStepProgress],
      extraction: FrameExtractionProgress?,
      hasPlan: Bool,
      statusText: String? = nil,
      framesComplete: Int,
      frameCount: Int,
      secondsRemaining: (ProcessingStepProgress) -> TimeInterval?
    ) -> MenuBarStatus {
        guard let sequenceName else { return .idle }
        if isRendering {
            return .rendering(fraction: min(1, max(0, renderFraction)))
        }
        guard isProcessing else { return .idle }
        let stage = ProcessingHeadline.text(
          steps: steps, extraction: extraction, hasPlan: hasPlan,
          framesComplete: framesComplete, frameCount: frameCount)
        return .processing(Run(
          sequenceName: sequenceName,
          stage: stage ?? statusText,
          framesDone: framesComplete,
          frameCount: frameCount,
          fraction: frameCount > 0 ? Double(framesComplete) / Double(frameCount) : 0,
          overall: ProcessingHeadline.overallText(steps: steps, secondsRemaining: secondsRemaining)))
    }
}

/// How the last run ended, kept until the user next opens the menu or starts a run.
enum RunOutcome: Equatable {
    case finished
    case failed
}

/// The latched outcome of the last run.  Cancelling sets nothing: a cancelled run just goes idle.
struct MenuBarOutcome: Equatable {
    private(set) var outcome: RunOutcome?

    mutating func runStarted() { outcome = nil }
    mutating func runEnded(_ outcome: RunOutcome) { self.outcome = outcome }
    mutating func menuOpened() { outcome = nil }
}

/// The four looks of the wand.  The raw values are the ids the desktop tray uses too.
enum MenuBarIcon: String, Equatable {
    case idle, running, finished, failed

    /// A run in progress wins over a stale outcome; then the outcome; then idle.
    static func of(_ status: MenuBarStatus, outcome: RunOutcome?) -> MenuBarIcon {
        if status != .idle { return .running }
        switch outcome {
        case .finished: return .finished
        case .failed: return .failed
        case nil: return .idle
        }
    }

    var symbolName: String? {
        switch self {
        case .idle: return "wand.and.stars.inverse"
        case .running: return nil
        case .finished: return "checkmark.circle"
        case .failed: return "exclamationmark.triangle"
        }
    }

    /// A template ring filled to `fraction`, in 5% steps so it is redrawn only when that changes.
    static func ringImage(fraction: Double) -> NSImage {
        let step = Int((min(1, max(0, fraction)) * 20).rounded(.down))
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let c = NSPoint(x: rect.midX, y: rect.midY)
            let r: CGFloat = 7
            let track = NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
            track.lineWidth = 1.5
            NSColor.black.withAlphaComponent(0.35).setStroke()
            track.stroke()
            if step > 0 {
                let arc = NSBezierPath()
                arc.appendArc(withCenter: c, radius: r, startAngle: 90,
                              endAngle: 90 - 360 * CGFloat(step) / 20, clockwise: true)
                arc.lineWidth = 2.5
                NSColor.black.setStroke()
                arc.stroke()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}

extension MenuBarStatus {
    /// The wand's tooltip and accessibility label: names the state.
    func tooltip(outcome: RunOutcome?) -> String {
        switch self {
        case .processing(let run):
            return localized("ui.menu_bar.tooltip.processing", Int(run.fraction * 100))
        case .rendering(let fraction):
            return localized("ui.menu_bar.tooltip.rendering", Int(fraction * 100))
        case .idle:
            switch outcome {
            case .finished: return localized("ui.menu_bar.tooltip.finished")
            case .failed: return localized("ui.menu_bar.tooltip.failed")
            case nil: return localized("ui.menu_bar.tooltip.idle")
            }
        }
    }

    /// The fraction the ring shows.
    var ringFraction: Double {
        switch self {
        case .idle: return 0
        case .processing(let run): return run.fraction
        case .rendering(let f): return f
        }
    }
}

/// The menu-bar extra's label: the icon for the state, redrawn only when the state or the 5% step changes.
struct MenuBarLabel: View {
    let viewModel: ViewModel

    var body: some View {
        let status = viewModel.imageSequence?.menuBarStatus ?? .idle
        let outcome = viewModel.menuBarOutcome.outcome
        let icon = MenuBarIcon.of(status, outcome: outcome)
        let tip = status.tooltip(outcome: outcome)
        Group {
            if let symbol = icon.symbolName {
                Image(systemName: symbol)
            } else {
                Image(nsImage: MenuBarIcon.ringImage(fraction: status.ringFraction))
            }
        }
          .help(tip)
          .accessibilityLabel(tip)
    }
}

extension ImageSequenceViewModel {
    /// The wand's content for the state the sequence is in now.  Reads only `@Observable`
    /// state, so a view that calls it is redrawn when a run moves, and costs nothing when none is.
    var menuBarStatus: MenuBarStatus {
        MenuBarStatus.make(
          sequenceName: config.config().imageSequenceDirname,
          isProcessing: isProcessingFrames,
          isRendering: isRenderingVideo,
          renderFraction: videoRenderFraction,
          steps: processingSteps,
          extraction: extractionProgress,
          hasPlan: processingHasPlan,
          statusText: processingStatusText ?? waitingForFramesText,
          framesComplete: count(for: .complete),
          frameCount: frames.count,
          secondsRemaining: { [stepRates] in stepRates.secondsRemaining(for: $0) })
    }
}

/// The body of the menu-bar wand's panel.
struct MenuBarStatusView: View {
    let viewModel: ViewModel

    var body: some View {
        let status = viewModel.imageSequence?.menuBarStatus ?? .idle
        content(status)
          .onAppear { viewModel.menuBarOutcome.menuOpened() }
          .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
              // The panel may stay alive between openings, so onAppear fires only once.
              if let window = note.object as? NSWindow, window is NSPanel {
                  viewModel.menuBarOutcome.menuOpened()
              }
          }
    }

    @ViewBuilder
    private func content(_ status: MenuBarStatus) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            switch status {
            case .idle:
                Text(localized("ui.menu_bar.idle"))
            case .rendering(let fraction):
                Text(localized("ui.menu_bar.rendering_video"))
                  .font(.headline)
                ProgressView(value: fraction)
                Text(fraction.formatted(.percent.precision(.fractionLength(0))))
                  .font(.caption)
                  .monospacedDigit()
                  .foregroundColor(.secondary)
            case .processing(let run):
                Text(run.sequenceName)
                  .font(.headline)
                  .lineLimit(1)
                  .truncationMode(.middle)
                if let stage = run.stage {
                    Text(stage)
                      .font(.caption)
                      .fixedSize(horizontal: false, vertical: true)
                }
                ProgressView(value: run.fraction)
                Text(localized("progress.frames_complete", run.framesDone, run.frameCount))
                  .font(.caption)
                  .monospacedDigit()
                  .foregroundColor(.secondary)
                if let overall = run.overall {
                    Text(overall)
                      .font(.caption)
                      .foregroundColor(.secondary)
                }
            }
        }
          .padding(12)
          .frame(width: 280, alignment: .leading)
    }
}
