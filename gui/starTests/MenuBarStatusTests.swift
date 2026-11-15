import XCTest
import AVFoundation
import SwiftUI
import Observation
import StarCore
import StarCppBridge
// The app target is named `Star`, not `star` — the lowercase name belongs to the .xcodeproj
// and to this test target.  TEST_HOST points at Star.app, so this is what links.
@testable import Star


/// What the menu-bar wand says (`MenuBarStatus`): idle, a processing run, a video render.  The processing cases check the wand
/// against what the processing modal builds from the same state — `ProcessingHeadline` for the stage and the time left, and
/// `progress.frames_complete` for the count under the modal's title — so the two cannot drift apart.
final class MenuBarStatusTests: XCTestCase {
    override func setUp() {
        StarLocalization.shared.languageOverride = "en"
    }

    override func tearDown() {
        StarLocalization.shared.languageOverride = nil
    }

    /// Two steps mid-run: star alignment running, merge still queued.
    private let steps = [
        ProcessingStepProgress(type: .starHomography, queued: 30, running: 4, done: 6),
        ProcessingStepProgress(type: .merge, queued: 40, running: 0, done: 0),
    ]

    private func status(
      sequenceName: String? = "night-1",
      isProcessing: Bool = true,
      isRendering: Bool = false,
      renderFraction: Double = 0,
      steps: [ProcessingStepProgress],
      secondsRemaining: @escaping (ProcessingStepProgress) -> TimeInterval? = { _ in nil }
    ) -> MenuBarStatus {
        MenuBarStatus.make(
          sequenceName: sequenceName, isProcessing: isProcessing, isRendering: isRendering, renderFraction: renderFraction,
          steps: steps, extraction: nil, hasPlan: true, framesComplete: 10, frameCount: 40,
          secondsRemaining: secondsRemaining)
    }

    private func run(_ status: MenuBarStatus, file: StaticString = #filePath, line: UInt = #line) throws -> MenuBarStatus.Run {
        guard case .processing(let run) = status else {
            XCTFail("expected a processing status, got \(status)", file: file, line: line)
            throw CancellationError()
        }
        return run
    }

    private let runningStatus = MenuBarStatus.rendering(fraction: 0.25)

    func testIconIdForEachState() {
        XCTAssertEqual(MenuBarIcon.of(.idle, outcome: nil).rawValue, "idle")
        XCTAssertEqual(MenuBarIcon.of(runningStatus, outcome: nil).rawValue, "running")
        XCTAssertEqual(MenuBarIcon.of(status(steps: steps), outcome: nil).rawValue, "running")
        XCTAssertEqual(MenuBarIcon.of(.idle, outcome: .finished).rawValue, "finished")
        XCTAssertEqual(MenuBarIcon.of(.idle, outcome: .failed).rawValue, "failed")
        // A run in progress beats a stale outcome.
        XCTAssertEqual(MenuBarIcon.of(runningStatus, outcome: .failed).rawValue, "running")
    }

    func testFinishedAndFailedClearOnMenuOpenAndRunStart() {
        var o = MenuBarOutcome()
        XCTAssertNil(o.outcome)
        o.runEnded(.finished)
        XCTAssertEqual(o.outcome, .finished)
        o.menuOpened()
        XCTAssertNil(o.outcome)
        o.runEnded(.failed)
        XCTAssertEqual(o.outcome, .failed)
        o.runStarted()
        XCTAssertNil(o.outcome)
        // Opening the menu with nothing latched changes nothing.
        o.menuOpened()
        XCTAssertNil(o.outcome)
    }

    func testTooltipNamesTheState() throws {
        XCTAssertEqual(MenuBarStatus.idle.tooltip(outcome: nil), "star — idle")
        XCTAssertEqual(MenuBarStatus.idle.tooltip(outcome: .finished), "star — finished")
        XCTAssertEqual(MenuBarStatus.idle.tooltip(outcome: .failed), "star — failed")
        XCTAssertEqual(status(steps: steps).tooltip(outcome: nil), "star — processing 25%")
        XCTAssertEqual(runningStatus.tooltip(outcome: nil), "star — rendering video 25%")
    }

    func testIdleWhenNothingIsRunning() {
        // No sequence open: idle, even with stale flags.
        XCTAssertEqual(status(sequenceName: nil, steps: steps), .idle)
        XCTAssertEqual(status(sequenceName: nil, isProcessing: true, isRendering: true, steps: steps), .idle)
        // A sequence that is open and doing nothing.
        XCTAssertEqual(status(isProcessing: false, steps: steps), .idle)
        XCTAssertEqual(localized("ui.menu_bar.idle"), "Idle")
    }

    func testProcessingMidRunMatchesTheModalNumbers() throws {
        let got = try run(status(steps: steps))
        XCTAssertEqual(got.sequenceName, "night-1")
        XCTAssertEqual(got.stage, ProcessingHeadline.text(
          steps: steps, extraction: nil, hasPlan: true, framesComplete: 10, frameCount: 40))
        XCTAssertEqual(got.stage, localized("ui.status.working_on", OperationType.starHomography.stepBrief))
        XCTAssertEqual(got.framesDone, 10)
        XCTAssertEqual(got.frameCount, 40)
        XCTAssertEqual(got.fraction, 0.25, accuracy: 1e-9)
        // The line under the modal's title is built from the same two numbers.
        XCTAssertEqual(localized("progress.frames_complete", got.framesDone, got.frameCount), "10 / 40 frames complete")
    }

    func testProcessingWithEtaUnknown() throws {
        // A tracker that has seen one sample has no rate, so the modal says nothing about time left, and neither does the wand.
        let rates = StepRateTracker()
        rates.observe(steps, at: Date(timeIntervalSince1970: 1000))
        XCTAssertNil(ProcessingHeadline.overallText(steps: steps, secondsRemaining: { rates.secondsRemaining(for: $0) }))
        let got = try run(status(steps: steps, secondsRemaining: { rates.secondsRemaining(for: $0) }))
        XCTAssertNil(got.overall)
    }

    func testProcessingWithEtaKnown() throws {
        // Star alignment goes from 6 to 16 done over 10 s: 34 left at 1/s is 34 s.  Merge has not started, so the figure is a floor.
        let start = Date(timeIntervalSince1970: 1000)
        let rates = StepRateTracker()
        rates.observe(steps, at: start)
        let later = [
            ProcessingStepProgress(type: .starHomography, queued: 20, running: 4, done: 16),
            ProcessingStepProgress(type: .merge, queued: 40, running: 0, done: 0),
        ]
        rates.observe(later, at: start.addingTimeInterval(10))
        let expected = ProcessingHeadline.overallText(steps: later, secondsRemaining: { rates.secondsRemaining(for: $0) })
        XCTAssertNotNil(expected)
        let got = try run(status(steps: later, secondsRemaining: { rates.secondsRemaining(for: $0) }))
        XCTAssertEqual(got.overall, expected)
        XCTAssertEqual(got.overall, localized("ui.status.overall_at_least", ProcessingHeadline.duration(24)))
    }

    func testRenderingShowsFraction() {
        XCTAssertEqual(status(isProcessing: false, isRendering: true, renderFraction: 0.4, steps: []), .rendering(fraction: 0.4))
        // Rendering wins over a stale processing flag, and the fraction stays in 0...1.
        XCTAssertEqual(status(isRendering: true, renderFraction: 1.7, steps: steps), .rendering(fraction: 1))
        XCTAssertEqual(localized("ui.menu_bar.rendering_video"), "Rendering video")
    }
}
