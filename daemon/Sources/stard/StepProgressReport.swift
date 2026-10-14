import Foundation
import StarCore
import StarDaemonMessages

/// How far each step of a run has got, worked out the way the macOS processing modal does it (StarCore's `ProcessingSteps`) from
/// `FrameGraphViewModel`'s counters, which only reset when a sequence is closed: so what a run reports is measured from a sample taken
/// as it started.
enum StepProgressReport {

    /// The counters at one moment.
    struct Sample: Sendable, Equatable {
        var operations: [OperationType: [OperationState: UInt]]
        var alreadyDone: [OperationType: UInt]
        var graphBuilds: Int
    }

    @MainActor
    static func sampleNow() -> Sample {
        Sample(operations: frameGraphViewModel.operations,
               alreadyDone: frameGraphViewModel.alreadyDone,
               graphBuilds: frameGraphViewModel.graphBuildsCompleted)
    }

    static func sample() async -> Sample { await MainActor.run { sampleNow() } }

    /// The report for `types` as of `now`, for a run that started at `baseline`.  `alreadyDone` describes whichever graph was built last,
    /// so until this run's is the one that was it belongs to nobody, and the same fact decides whether steps with nothing to do are left out.
    static func make(types: [OperationType], now: Sample, baseline: Sample, status: String? = nil) -> Star_V1_StepProgress {
        let graphIsBuilt = now.graphBuilds > baseline.graphBuilds
        let steps = ProcessingSteps.visible(
            ProcessingSteps.progress(for: types, counts: now.operations, since: baseline.operations,
                                     alreadyDone: graphIsBuilt ? now.alreadyDone : [:]),
            graphIsBuilt: graphIsBuilt)
        var report = Star_V1_StepProgress()
        report.graphBuilt = graphIsBuilt
        report.status = status ?? ""
        report.steps = steps.map(stepCount)
        return report
    }

    static func stepCount(_ step: ProcessingStepProgress) -> Star_V1_StepCount {
        var count = Star_V1_StepCount()
        count.type = "\(step.type)"   // the case's name ("starKeypoints"), not its raw value ("star kp")
        count.queued = Int32(step.queued)
        count.running = Int32(step.running)
        count.done = Int32(step.done)
        count.alreadyDone = Int32(step.alreadyDone)
        return count
    }

    static func proto(_ progress: SequenceProgress) -> Star_V1_SequenceProgress {
        var out = Star_V1_SequenceProgress()
        out.sequenceName = progress.sequenceName
        out.frameCount = Int32(progress.frameCount)
        out.framesComplete = Int32(progress.framesComplete)
        out.steps = progress.steps.map(stepCount)
        out.isUntouched = progress.isUntouched
        out.isComplete = progress.isComplete
        return out
    }
}
