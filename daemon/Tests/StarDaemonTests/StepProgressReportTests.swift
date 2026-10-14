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

    private func steps(_ report: Star_V1_StepProgress) -> [String: [Int32]] {
        Dictionary(uniqueKeysWithValues: report.steps.map { ($0.type, [$0.queued, $0.running, $0.done, $0.alreadyDone]) })
    }

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

    func testAReportThatHasNotChangedEqualsTheLastOne() {
        let a = StepProgressReport.make(types: [.horizon], now: sample([.horizon: [.done: 1]], builds: 1), baseline: sample())
        let b = StepProgressReport.make(types: [.horizon], now: sample([.horizon: [.done: 1]], builds: 1), baseline: sample())
        XCTAssertEqual(a, b, "the session sends a report only when it differs from the last")
    }
}
