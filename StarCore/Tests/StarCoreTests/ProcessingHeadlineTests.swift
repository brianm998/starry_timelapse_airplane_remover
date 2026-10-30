import XCTest
@testable import StarCore

final class ProcessingHeadlineTests: XCTestCase {
    private func step(_ type: OperationType, queued: Int = 0, running: Int = 0, done: Int = 0) -> ProcessingStepProgress {
        ProcessingStepProgress(type: type, queued: queued, running: running, done: done)
    }

    private func text(_ steps: [ProcessingStepProgress], hasPlan: Bool = true, complete: Int = 0) -> String? {
        ProcessingHeadline.text(steps: steps, extraction: nil, hasPlan: hasPlan, framesComplete: complete,
                                frameCount: 10)
    }

    func testPlanningUntilTheGraphIsBuilt() {
        XCTAssertEqual(text([step(.horizon)], hasPlan: false), localized("ui.status.planning"))
    }

    func testNamesEveryRunningStep() {
        let steps = [step(.horizon, queued: 3, running: 2, done: 5), step(.starKeypoints, queued: 5, running: 2, done: 3),
                     step(.earthHomography, queued: 4), step(.merge, queued: 10)]
        let expected = localized("ui.status.working_on",
                                 "\(OperationType.horizon.stepBrief), \(OperationType.starKeypoints.stepBrief)")
        XCTAssertEqual(text(steps), expected)
    }

    func testFallsBackToTheFirstQueuedStepWhenNothingIsRunning() {
        let steps = [step(.horizon, done: 10), step(.starKeypoints, queued: 10)]
        XCTAssertEqual(text(steps), OperationType.starKeypoints.stepActivity)
    }

    func testOverallEstimateIsTheSlowestMeasuredStep() {
        let steps = [step(.horizon, queued: 3, running: 2, done: 5), step(.starKeypoints, queued: 5, running: 2, done: 3)]
        let eta: (ProcessingStepProgress) -> TimeInterval? = { $0.type == .horizon ? 120 : 600 }
        XCTAssertEqual(ProcessingHeadline.overallText(steps: steps, secondsRemaining: eta),
                       localized("ui.status.overall_about", localized("duration.minutes", 10)))
    }

    func testOverallEstimateAdmitsWhatItCannotSeeYet() {
        let steps = [step(.starKeypoints, queued: 5, running: 2, done: 3), step(.merge, queued: 10)]
        let eta: (ProcessingStepProgress) -> TimeInterval? = { $0.type == .merge ? nil : 600 }
        XCTAssertEqual(ProcessingHeadline.overallText(steps: steps, secondsRemaining: eta),
                       localized("ui.status.overall_at_least", localized("duration.minutes", 10)))
        XCTAssertNil(ProcessingHeadline.overallText(steps: steps, secondsRemaining: { _ in nil }))
    }

    func testFinishingWhileFramesRemainAndQuietOnceDone() {
        let done = [step(.merge, done: 10)]
        XCTAssertEqual(text(done, complete: 9), localized("ui.status.finishing"))
        XCTAssertNil(text(done, complete: 10))
    }

    func testRateNeedsOperationsAndTime() {
        let tracker = StepRateTracker()
        let t0 = Date()
        tracker.observe([step(.merge, queued: 8, running: 2, done: 0)], at: t0)
        let later = step(.merge, queued: 6, running: 2, done: 2)
        tracker.observe([later], at: t0.addingTimeInterval(1))
        XCTAssertNil(tracker.secondsRemaining(for: later), "one second is not enough to measure a rate")
        let end = step(.merge, queued: 4, running: 2, done: 4)
        tracker.observe([end], at: t0.addingTimeInterval(8))
        // 4 operations in 8 seconds, 6 left.
        XCTAssertEqual(tracker.secondsRemaining(for: end)!, 12, accuracy: 0.001)
    }

    func testDurationRoundsCoarsely() {
        XCTAssertEqual(ProcessingHeadline.duration(3), localized("duration.seconds", 5))
        XCTAssertEqual(ProcessingHeadline.duration(100), localized("duration.minutes", 2))
        XCTAssertEqual(ProcessingHeadline.duration(5400), localized("duration.hours_minutes", 1, 30))
    }
}
