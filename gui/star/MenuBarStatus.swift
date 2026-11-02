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
