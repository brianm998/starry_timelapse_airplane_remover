import Foundation

/// How fast each step of a run is finishing its operations, for the "about N left" the
/// processing modal puts under its title.
///
/// A step's rate is measured from the first moment it was seen working, not from the start
/// of the run: the steps overlap, so a step that spent minutes queued behind the one before
/// it would otherwise look slow for the whole of its turn.  Nothing is estimated until a
/// step has finished a couple of operations over a few seconds — a rate from one sample is a
/// guess, and a wrong estimate that then shrinks reads worse than none.
public final class StepRateTracker {
    private struct Sample { let time: Date; let done: Int }
    private var starts: [OperationType: Sample] = [:]
    private var latest: [OperationType: Sample] = [:]

    public static let minimumOperations = 2
    public static let minimumSeconds: TimeInterval = 3

    public init() {}

    /// Record where each step has got to.  Safe to call as often as is convenient.
    public func observe(_ steps: [ProcessingStepProgress], at now: Date = Date()) {
        for step in steps where step.hasWork {
            let sample = Sample(time: now, done: step.done)
            if starts[step.type] == nil, step.running > 0 || step.done > 0 {
                starts[step.type] = sample
            }
            latest[step.type] = sample
        }
    }

    /// Seconds `step` has left at the rate it has been going, or nil while there is no
    /// rate to go on.
    public func secondsRemaining(for step: ProcessingStepProgress) -> TimeInterval? {
        guard let start = starts[step.type], let now = latest[step.type] else { return nil }
        let operations = now.done - start.done
        let seconds = now.time.timeIntervalSince(start.time)
        guard operations >= Self.minimumOperations, seconds >= Self.minimumSeconds else { return nil }
        let remaining = step.queued + step.running
        return Double(remaining) * seconds / Double(operations)
    }
}

/// The short lines under the modal's title: what star is working on right now, across every
/// step that is running, and how long the whole run has left.  Per-step estimates are not
/// part of the sentence; the modal puts each beside its own bar.
public enum ProcessingHeadline {

    /// - Parameters:
    ///   - steps: the visible steps, in pipeline order (`ProcessingSteps.visible`).
    ///   - hasPlan: whether this run's operations have been built; until then every step
    ///     reads as empty, which is "still planning", not "nothing to do".
    public static func text(
      steps: [ProcessingStepProgress],
      extraction: FrameExtractionProgress?,
      hasPlan: Bool,
      framesComplete: Int,
      frameCount: Int
    ) -> String? {
        let working = steps.filter { $0.hasWork && ($0.queued > 0 || $0.running > 0) }
        let running = working.filter { $0.running > 0 }
        // Every step that is running, not only the farthest advanced: the steps overlap, and
        // naming one of them reads as the others standing idle.  When nothing is running yet,
        // the first queued step is what is about to start.
        let active = running.first ?? working.first

        if let extraction, !extraction.isComplete, extraction.error == nil, active == nil {
            return withEstimate(localized("ui.status.extracting"),
                                extraction.estimatedSecondsRemaining, key: "ui.status.left_overall")
        }
        guard hasPlan else { return localized("ui.status.planning") }
        guard let active else {
            if steps.isEmpty { return nil }
            return framesComplete < frameCount ? localized("ui.status.finishing") : nil
        }
        if running.isEmpty { return active.type.stepActivity }
        return localized("ui.status.working_on", running.map { $0.type.stepBrief }.joined(separator: ", "))
    }

    /// How long the whole run has left, for the top of the modal: until every merged frame
    /// is written.  The steps overlap, so the slowest measured step sets the pace; a step
    /// that has not started has no rate yet, and its time is not in the figure, which then
    /// says so rather than promising a finish it cannot back.
    public static func overallText(
      steps: [ProcessingStepProgress],
      secondsRemaining: (ProcessingStepProgress) -> TimeInterval?
    ) -> String? {
        let working = steps.filter { $0.hasWork && ($0.queued > 0 || $0.running > 0) }
        let known = working.compactMap { secondsRemaining($0) }.filter { $0.isFinite }
        guard let longest = known.max() else { return nil }
        let key = known.count == working.count ? "ui.status.overall_about" : "ui.status.overall_at_least"
        return localized(key, duration(longest))
    }

    private static func withEstimate(_ sentence: String, _ seconds: TimeInterval?, key: String) -> String {
        guard let seconds, seconds.isFinite else { return sentence }
        return sentence + " " + localized(key, duration(seconds))
    }

    /// "about" precision: a minute is the finest grain worth showing past the first, and
    /// a figure to the second would imply an accuracy the rate does not have.
    public static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds).rounded())
        if total < 60 { return localized("duration.seconds", max(5, (total + 2) / 5 * 5)) }
        let minutes = (total + 30) / 60
        if minutes < 60 { return localized("duration.minutes", minutes) }
        return localized("duration.hours_minutes", minutes / 60, minutes % 60)
    }
}

extension OperationType {
    /// The same activity in a few words, to list beside others.
    public var stepBrief: String {
        switch self {
        case .horizon:          localized("ui.status.brief.horizon")
        case .mergedHorizon:    localized("ui.status.brief.merged_horizon")
        case .starKeypoints:    localized("ui.status.brief.star_keypoints")
        case .earthKeypoints:   localized("ui.status.brief.earth_keypoints")
        case .starHomography:   localized("ui.status.brief.star_alignment")
        case .earthHomography:  localized("ui.status.brief.earth_alignment")
        case .horizonConsensus: localized("ui.status.brief.horizon_consensus")
        case .outliers:         localized("ui.status.brief.outliers")
        case .merge:            localized("ui.status.brief.merged")
        default:                ""
        }
    }

    /// What this step is doing and why, as one sentence for the modal's header.  The longer
    /// account, with what it costs, is `stepHelp`.
    public var stepActivity: String {
        switch self {
        case .horizon:          localized("ui.status.horizon")
        case .mergedHorizon:    localized("ui.status.merged_horizon")
        case .starKeypoints:    localized("ui.status.star_keypoints")
        case .earthKeypoints:   localized("ui.status.earth_keypoints")
        case .starHomography:   localized("ui.status.star_alignment")
        case .earthHomography:  localized("ui.status.earth_alignment")
        case .horizonConsensus: localized("ui.status.horizon_consensus")
        case .outliers:         localized("ui.status.outliers")
        case .merge:            localized("ui.status.merged")
        default:                ""
        }
    }
}
