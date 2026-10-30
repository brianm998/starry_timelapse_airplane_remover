import XCTest
import StarCore
import StarDaemonMessages
@testable import stard

/// The per-step report a run sends: StarCore's step arithmetic over the frame graph's counters, measured from where the run began.
final class StepProgressReportTests: XCTestCase {

    private typealias Sample = StepProgressReport.Sample

    private func sample(_ operations: [OperationType: [OperationState: UInt]] = [:],
                        alreadyDone: [OperationType: UInt] = [:], builds: Int = 0) -> Sample {
        Sample(operations: operations, alreadyDone: alreadyDone, graphBuilds: builds)
    }

    private func steps(_ counts: [Star_V1_StepCount]) -> [String: [Int32]] {
        Dictionary(uniqueKeysWithValues: counts.map { ($0.type, [$0.queued, $0.running, $0.done, $0.alreadyDone]) })
    }

    private func steps(_ report: Star_V1_StepProgress) -> [String: [Int32]] { steps(report.steps) }

    /// Until the run's graph is built, every step is listed (none has any operations yet, and filtering would empty the panel and then
    /// pop the rows in one at a time).
    func testBeforeTheGraphIsBuiltEveryStepIsListedAndNothingIsAlreadyDone() {
        let report = StepProgressReport.make(types: [.horizon, .starKeypoints, .merge], now: sample(alreadyDone: [.horizon: 9]),
                                             baseline: sample())
        XCTAssertFalse(report.graphBuilt)
        XCTAssertEqual(report.steps.map(\.type), ["horizon", "starKeypoints", "merge"], "the case's name, not its raw value")
        XCTAssertEqual(steps(report)["horizon"], [0, 0, 0, 0], "an earlier graph's already-done count belongs to nobody yet")
    }

    func testOnceTheGraphIsBuiltAStepWithNothingToDoIsLeftOut() {
        let now = sample([.horizon: [.queued: 2, .running: 1, .done: 3], .merge: [:]], alreadyDone: [.starKeypoints: 4], builds: 1)
        let report = StepProgressReport.make(types: [.horizon, .starKeypoints, .earthKeypoints, .merge], now: now, baseline: sample())
        XCTAssertTrue(report.graphBuilt)
        XCTAssertEqual(steps(report), ["horizon": [2, 1, 3, 0], "starKeypoints": [0, 0, 0, 4]],
                       "the ones with operations or with work already on disk stay; the others have nothing to do")
    }

    /// The counters only reset when a sequence closes, so a second run starts with the first one's operations already in them.
    func testTheCountsAreThisRunsAndNotTheLastOnes() {
        let before = sample([.horizon: [.done: 10]], builds: 1)
        let now = sample([.horizon: [.queued: 1, .running: 2, .done: 14]], builds: 2)
        let report = StepProgressReport.make(types: [.horizon], now: now, baseline: before)
        XCTAssertEqual(steps(report)["horizon"], [1, 2, 4, 0], "7 operations this run: 4 done, 2 running, 1 queued")
    }

    func testAStatusLineIsPassedOn() {
        let report = StepProgressReport.make(types: [.merge], now: sample(), baseline: sample(), status: "preparing 3 frames")
        XCTAssertEqual(report.status, "preparing 3 frames")
        XCTAssertEqual(StepProgressReport.make(types: [.merge], now: sample(), baseline: sample()).status, "")
    }

    /// The gui's "Limited by: X" under Use of this Mac: the governor's verdict rides on the step report, and "not sampled yet" is not
    /// "not limited".
    func testTheResourceTheGovernorBlamesIsPassedOn() {
        let none = StepProgressReport.make(types: [.merge], now: sample(), baseline: sample())
        XCTAssertFalse(none.resourcesSampled, "no report from the governor yet")
        XCTAssertEqual(none.limitedBy, "")

        let free = StepProgressReport.make(types: [.merge], now: sample(), baseline: sample(), governor: .init(limitedBy: nil))
        XCTAssertTrue(free.resourcesSampled)
        XCTAssertEqual(free.limitedBy, "", "sampled and nothing limits the run")

        for (resource, text) in [(LimitingResource.gpu, "GPU"), (.cpu, "CPU"), (.memory, "memory"), (.disk("/Volumes/rp"), "disk /Volumes/rp")] {
            let report = StepProgressReport.make(types: [.merge], now: sample(), baseline: sample(), governor: .init(limitedBy: resource))
            XCTAssertTrue(report.resourcesSampled)
            XCTAssertEqual(report.limitedBy, text)
        }
        XCTAssertNotEqual(none, free, "the session sends a report again when only this changes")
    }

    func testAReportThatHasNotChangedEqualsTheLastOne() {
        let a = StepProgressReport.make(types: [.horizon], now: sample([.horizon: [.done: 1]], builds: 1), baseline: sample())
        let b = StepProgressReport.make(types: [.horizon], now: sample([.horizon: [.done: 1]], builds: 1), baseline: sample())
        XCTAssertEqual(a, b, "the session sends a report only when it differs from the last")
    }

    // MARK: - the survey of a reopened sequence

    /// What the survey found on disk goes to the client as it is — including the two verdicts, which the client takes from here rather
    /// than working them out again, and a step with nothing found, which is a row at zero and not a missing row.
    func testASurveyedSequenceIsSentWithItsVerdicts() {
        let types: [OperationType] = [.horizon, .starKeypoints, .merge]
        let progress = SequenceProgress(
            sequenceName: "a_sequence", frameCount: 10, framesComplete: 0,
            steps: SequenceProgressSurvey.steps(for: types, frameCount: 10, framesOnDisk: [.horizon: 10, .starKeypoints: 4]))
        let sent = StepProgressReport.proto(progress)

        XCTAssertEqual(sent.sequenceName, "a_sequence")
        XCTAssertEqual(sent.frameCount, 10)
        XCTAssertEqual(sent.framesComplete, 0)
        XCTAssertEqual(sent.steps.map(\.type), ["horizon", "starKeypoints", "merge"])
        XCTAssertEqual(steps(sent.steps), ["horizon": [0, 0, 0, 10], "starKeypoints": [6, 0, 0, 4], "merge": [10, 0, 0, 0]])
        XCTAssertFalse(sent.isUntouched, "keypoints and horizons found: that is most of the work, not a sequence nothing was done to")
        XCTAssertFalse(sent.isComplete)
    }

    /// Work the next run will make again goes to the client flagged, so its panel can say why a sequence that looks finished is not.
    func testASequenceToBeRebuiltIsSentFlagged() {
        let progress = SequenceProgress(
            sequenceName: "older", frameCount: 3, framesComplete: 0,
            steps: SequenceProgressSurvey.steps(for: [.merge], frameCount: 3, framesOnDisk: [:]),
            staleStages: [.horizonConsensus, .outliers, .output])
        let sent = StepProgressReport.proto(progress)
        XCTAssertTrue(sent.needsRebuild)
        XCTAssertFalse(sent.isComplete)
        XCTAssertFalse(StepProgressReport.proto(SequenceProgress(
            sequenceName: "current", frameCount: 3, framesComplete: 3, steps: [])).needsRebuild)
    }

    func testASequenceWithEveryFrameWrittenIsComplete() {
        let progress = SequenceProgress(
            sequenceName: "done", frameCount: 3, framesComplete: 3,
            steps: SequenceProgressSurvey.steps(for: [.merge], frameCount: 3, framesOnDisk: [.merge: 3]))
        XCTAssertTrue(StepProgressReport.proto(progress).isComplete)
        XCTAssertFalse(StepProgressReport.proto(progress).isUntouched)
    }

    func testASequenceNothingWasDoneToIsUntouched() {
        let progress = SequenceProgress(
            sequenceName: "new", frameCount: 3, framesComplete: 0,
            steps: SequenceProgressSurvey.steps(for: [.horizon, .merge], frameCount: 3, framesOnDisk: [:]))
        XCTAssertTrue(StepProgressReport.proto(progress).isUntouched)
        XCTAssertFalse(StepProgressReport.proto(progress).isComplete)
    }
}
