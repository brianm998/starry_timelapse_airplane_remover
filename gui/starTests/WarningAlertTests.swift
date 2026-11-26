import XCTest
import AVFoundation
import SwiftUI
import Observation
import StarCore
import StarCppBridge
// The app target is named `Star`, not `star` — the lowercase name belongs to the .xcodeproj
// and to this test target.  TEST_HOST points at Star.app, so this is what links.
@testable import Star


/// The low-memory alert, which used to take the window with it.
///
/// `ContentView` draws its own panels as siblings inside the root `ZStack`, and a sibling's
/// layout is the window's layout: whatever minimum size the panel needs becomes a minimum
/// size the window must satisfy.  The warning panel asked for an unbounded height — its
/// message and suggestion were `fixedSize`d vertically, so at a narrow width they grow
/// without limit — and AppKit duly grew the window to fit.  A user processing a 4240x2832
/// sequence ended up with a window 3104 points tall (measured; the screen is 1440), most of
/// it off screen, which could not be shrunk while the alert was up.
///
/// So the invariant is not about the alert's own size: it is that showing the alert does not
/// change what the window is asked to be.  A system alert is a separate window and satisfies
/// that by construction, which is what these tests pin down — along with the other half of
/// the report, an alert that came back after the user pressed OK.
@MainActor
final class WarningAlertTests: XCTestCase {

    // MARK: - window sizing

    /// The regression itself.  One window, one hosted `ContentView`, the flag toggled
    /// underneath it: the window's minimum content size and its actual content size must both
    /// come out the same as they went in.
    ///
    /// The sizing options are the ones a SwiftUI `WindowGroup` uses, so the hosting view
    /// pushes the content's minimum, ideal and maximum sizes onto the window exactly as the
    /// real app does.
    func testShowingTheAlertDoesNotResizeTheWindowOrRaiseItsMinimum() {
        let viewModel = ViewModel()
        let host = NSHostingView(rootView: ContentView().environment(viewModel))
        host.sizingOptions = [.minSize, .intrinsicContentSize, .maxSize]

        let window = OffDisplayWindow(contentRect: OffDisplayWindow.farAway,
                                      styleMask: [.titled, .resizable, .closable],
                                      backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        window.contentView = host
        window.setContentSize(NSSize(width: 900, height: 600))
        settle()

        let quietMinimum = window.contentMinSize
        let quietContent = host.frame.size

        viewModel.report(warning: warning(.memoryPressure, .critical))
        XCTAssertTrue(viewModel.showWarningAlert, "a critical warning should reach the alert")
        settle()
        OffDisplayWindow.assertNothingShowsOnADisplay()

        XCTAssertEqual(window.contentMinSize, quietMinimum,
                       "the alert must not raise the window's minimum size")
        XCTAssertEqual(host.frame.size, quietContent,
                       "the alert must not resize the window it appears over")

        viewModel.acknowledgeWarning()
        settle()

        XCTAssertEqual(window.contentMinSize, quietMinimum)
        XCTAssertEqual(host.frame.size, quietContent,
                       "and dismissing it must not resize the window either")
    }

    // MARK: - what interrupts

    /// Only `critical` gets a modal.  Everything else goes to the banner — a modal for a
    /// condition the user cannot act on teaches them to click through the one they can.
    func testAWarningSeverityConditionDoesNotInterrupt() {
        let viewModel = ViewModel()
        viewModel.report(warning: warning(.memoryPressure, .warning))

        XCTAssertFalse(viewModel.showWarningAlert)
        XCTAssertEqual(viewModel.latestWarning?.severity, .warning,
                       "it is still recorded, just not in front of the user")
        XCTAssertEqual(viewModel.bannerWarning?.kind, .memoryPressure,
                       "and it is somewhere the user can see it")
    }

    func testACriticalConditionInterrupts() {
        let viewModel = ViewModel()
        viewModel.report(warning: warning(.memoryPressure, .critical))

        XCTAssertTrue(viewModel.showWarningAlert)
        XCTAssertEqual(viewModel.warningTitle, StarWarning.Kind.memoryPressure.titleForTest)
        XCTAssertTrue(viewModel.warningMessage.contains("holding"))
    }

    // MARK: - pressing OK

    func testAcknowledgingClosesTheAlert() {
        let viewModel = ViewModel()
        viewModel.report(warning: warning(.memoryPressure, .critical))
        viewModel.acknowledgeWarning()

        XCTAssertFalse(viewModel.showWarningAlert)
    }

    /// The other half of the report: the alert came back.  These conditions are sampled for as
    /// long as they last and `StarWarnings` re-delivers the same kind every 30 seconds, so
    /// pressing OK has to mean "I have read this", not "hide it for half a minute".
    func testAConditionTheUserHasAcknowledgedDoesNotInterruptAgain() {
        let viewModel = ViewModel()
        viewModel.report(warning: warning(.memoryPressure, .critical))
        viewModel.acknowledgeWarning()

        viewModel.report(warning: warning(.memoryPressure, .critical))

        XCTAssertFalse(viewModel.showWarningAlert,
                       "the same condition must not put the same alert back up")
        XCTAssertEqual(viewModel.latestWarning?.kind, .memoryPressure,
                       "it is still recorded")
    }

    /// Acknowledging one condition is not acknowledging the next one.
    func testADifferentConditionStillInterrupts() {
        let viewModel = ViewModel()
        viewModel.report(warning: warning(.memoryPressure, .critical))
        viewModel.acknowledgeWarning()

        viewModel.report(warning: warning(.outputWriteFailed, .critical))

        XCTAssertTrue(viewModel.showWarningAlert)
    }

    /// Acknowledgement is scoped to what the user acknowledged, not to whatever was reported
    /// most recently: a `warning` arriving between the alert going up and OK being pressed
    /// must not be the thing that gets silenced.
    func testANonInterruptingWarningInBetweenDoesNotStealTheAcknowledgement() {
        let viewModel = ViewModel()
        viewModel.report(warning: warning(.memoryPressure, .critical))
        viewModel.report(warning: warning(.lowDiskSpace, .warning))
        viewModel.acknowledgeWarning()

        viewModel.report(warning: warning(.memoryPressure, .critical))
        XCTAssertFalse(viewModel.showWarningAlert, "memory pressure is what was acknowledged")

        viewModel.report(warning: warning(.lowDiskSpace, .critical))
        XCTAssertTrue(viewModel.showWarningAlert, "the disk was not")
    }

    /// A condition acknowledged about the sequence just closed should not stay acknowledged
    /// for the next one.
    func testClosingTheSequenceForgetsWhatWasAcknowledged() {
        let viewModel = ViewModel()
        viewModel.report(warning: warning(.memoryPressure, .critical))
        viewModel.acknowledgeWarning()

        viewModel.unloadSequence()
        viewModel.report(warning: warning(.memoryPressure, .critical))

        XCTAssertTrue(viewModel.showWarningAlert)
    }

    // MARK: - the banner

    /// The banner is the whole reason a non-interrupting severity is worth having: before it
    /// existed, a `warning` in the gui went to the log and nowhere else, which in an app with
    /// no terminal means nowhere at all.
    func testTheBannerShowsWhatDidNotInterrupt() {
        let viewModel = ViewModel()
        viewModel.report(warning: warning(.footprintOverBudget, .warning))

        XCTAssertEqual(viewModel.bannerWarning?.kind, .footprintOverBudget)
        XCTAssertFalse(viewModel.showWarningAlert)
    }

    /// A condition that gets the modal does not also get the banner: the user is already
    /// reading it.
    func testAConditionThatInterruptsDoesNotAlsoGetABanner() {
        let viewModel = ViewModel()
        viewModel.report(warning: warning(.memoryPressure, .critical))

        XCTAssertTrue(viewModel.showWarningAlert)
        XCTAssertNil(viewModel.bannerWarning)
    }

    /// And dismissing the alert does not leave the same sentence behind to be dismissed a
    /// second time.
    func testAcknowledgingTheAlertLeavesNoBanner() {
        let viewModel = ViewModel()
        viewModel.report(warning: warning(.memoryPressure, .critical))
        viewModel.acknowledgeWarning()

        XCTAssertNil(viewModel.bannerWarning)
    }

    /// The pair of the suppression test above: an acknowledged condition that happens again
    /// is not silent, it is quiet.  This is what a long run under memory pressure looks like
    /// — one alert, then the banner for as long as it lasts.
    func testARepeatOfAnAcknowledgedConditionGoesToTheBanner() {
        let viewModel = ViewModel()
        viewModel.report(warning: warning(.memoryPressure, .critical))
        viewModel.acknowledgeWarning()

        viewModel.report(warning: warning(.memoryPressure, .critical))

        XCTAssertFalse(viewModel.showWarningAlert)
        XCTAssertEqual(viewModel.bannerWarning?.kind, .memoryPressure)
        XCTAssertEqual(viewModel.bannerWarning?.severity, .critical,
                       "the banner colours by severity, so it must keep it")
    }

    func testDismissingTheBannerTakesItDown() {
        let viewModel = ViewModel()
        viewModel.report(warning: warning(.memoryPressure, .warning))
        viewModel.dismissBanner()

        XCTAssertNil(viewModel.bannerWarning)
    }

    /// The newest report wins.  These arrive at most every 30 seconds per kind, so a queue
    /// would be showing the user a condition from several minutes ago.
    func testANewerWarningReplacesWhatTheBannerWasShowing() {
        let viewModel = ViewModel()
        viewModel.report(warning: warning(.footprintOverBudget, .warning))
        viewModel.report(warning: warning(.lowSystemMemory, .warning))

        XCTAssertEqual(viewModel.bannerWarning?.kind, .lowSystemMemory)
    }

    /// A machine state that has passed takes its banner with it: a strip still saying the
    /// system is short of memory ten minutes after it stopped being true is worse than no
    /// strip at all.
    func testABannerAboutAPassingConditionTakesItselfDown() async {
        let viewModel = ViewModel()
        viewModel.bannerLifetime = 0.1
        viewModel.report(warning: warning(.memoryPressure, .warning))
        XCTAssertNotNil(viewModel.bannerWarning)

        await waitForBannerToClear(viewModel)
        XCTAssertNil(viewModel.bannerWarning)
    }

    /// Whereas a fact about the run does not stop being true, and is posted once — so a banner
    /// that expired could take it away before anyone read it.
    func testABannerAboutTheRunItselfStaysUntilDismissed() async {
        let viewModel = ViewModel()
        viewModel.bannerLifetime = 0.1
        viewModel.report(warning: warning(.outputWriteFailed, .warning))

        await waitForBannerToClear(viewModel)
        XCTAssertEqual(viewModel.bannerWarning?.kind, .outputWriteFailed,
                       "an output write failure must not time out")
    }

    /// Each report restarts the clock, which is what keeps the banner up for as long as a
    /// condition keeps being reported.
    func testAFreshReportRestartsTheBannerClock() async {
        let viewModel = ViewModel()
        viewModel.bannerLifetime = 0.4
        viewModel.report(warning: warning(.memoryPressure, .warning))

        try? await Task.sleep(nanoseconds: 300_000_000)
        viewModel.report(warning: warning(.memoryPressure, .warning))
        try? await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertNotNil(viewModel.bannerWarning,
                        "the first timer must not take down the second warning")
    }

    func testClosingTheSequenceTakesTheBannerDown() {
        let viewModel = ViewModel()
        viewModel.report(warning: warning(.memoryPressure, .warning))
        viewModel.unloadSequence()

        XCTAssertNil(viewModel.bannerWarning)
    }

    /// The banner is an overlay rather than another member of the root `ZStack`, so that it
    /// cannot do what the old warning panel did to the window.  Same measurement as the alert
    /// test above.
    func testShowingTheBannerDoesNotResizeTheWindowOrRaiseItsMinimum() {
        let viewModel = ViewModel()
        let host = NSHostingView(rootView: ContentView().environment(viewModel))
        host.sizingOptions = [.minSize, .intrinsicContentSize, .maxSize]

        let window = OffDisplayWindow(contentRect: OffDisplayWindow.farAway,
                                      styleMask: [.titled, .resizable, .closable],
                                      backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        window.contentView = host
        window.setContentSize(NSSize(width: 900, height: 600))
        settle()

        let quietMinimum = window.contentMinSize
        let quietContent = host.frame.size

        viewModel.report(warning: warning(.memoryPressure, .warning))
        XCTAssertNotNil(viewModel.bannerWarning)
        settle()
        OffDisplayWindow.assertNothingShowsOnADisplay()

        XCTAssertEqual(window.contentMinSize, quietMinimum,
                       "the banner must not raise the window's minimum size")
        XCTAssertEqual(host.frame.size, quietContent,
                       "the banner must not resize the window it appears over")
    }

    // MARK: - restarting the run that stopped

    /// The whole point of the button: a report of a run that died with a config star can
    /// still find offers to pick it up, rather than only an OK that loses it.
    func testAReportOfAStoppedRunOffersARestart() {
        let viewModel = ViewModel()
        viewModel.report(warning: warning(.previousRunDied, .critical),
                         restartableConfigPath: "/tmp/star_temp_seq/config.json")

        XCTAssertTrue(viewModel.showWarningAlert)
        XCTAssertEqual(viewModel.restartableRunConfigPath, "/tmp/star_temp_seq/config.json")
    }

    /// The same alert carries the machine warnings, where there is no run to restart and a
    /// button offering one would be a lie.
    func testAMachineWarningOffersNoRestart() {
        let viewModel = ViewModel()
        viewModel.report(warning: warning(.memoryPressure, .critical))

        XCTAssertTrue(viewModel.showWarningAlert)
        XCTAssertNil(viewModel.restartableRunConfigPath)
    }

    /// The path's lifetime is the alert's.  Without this, a memory-pressure alert raised
    /// later in the session would inherit the dead run's button and restart a sequence
    /// nobody asked about.
    func testAcknowledgingForgetsWhatThereWasToRestart() {
        let viewModel = ViewModel()
        viewModel.report(warning: warning(.previousRunDied, .critical),
                         restartableConfigPath: "/tmp/star_temp_seq/config.json")
        viewModel.acknowledgeWarning()

        XCTAssertNil(viewModel.restartableRunConfigPath)

        viewModel.report(warning: warning(.memoryPressure, .critical))
        XCTAssertTrue(viewModel.showWarningAlert)
        XCTAssertNil(viewModel.restartableRunConfigPath,
                     "the next alert must not inherit the last one's restart")
    }

    /// A report that went to the banner instead — a repeat of a condition already
    /// acknowledged — has no alert to hang a button on.
    func testARestartableReportThatDoesNotInterruptOffersNoButton() {
        let viewModel = ViewModel()
        viewModel.report(warning: warning(.previousRunDied, .critical),
                         restartableConfigPath: "/tmp/star_temp_seq/config.json")
        viewModel.acknowledgeWarning()

        viewModel.report(warning: warning(.previousRunDied, .critical),
                         restartableConfigPath: "/tmp/star_temp_seq/config.json")

        XCTAssertFalse(viewModel.showWarningAlert)
        XCTAssertNil(viewModel.restartableRunConfigPath)
        XCTAssertEqual(viewModel.bannerWarning?.kind, .previousRunDied)
    }

    /// Pressing it acknowledges the report on the way past, so a second abandoned marker
    /// cannot put the same alert straight back up over the sequence that is now loading.
    /// The load itself is not exercised here — there is no sequence at this path — which is
    /// also what keeps the test from starting a run.
    func testRestartingAcknowledgesTheReport() {
        let viewModel = ViewModel()
        viewModel.report(warning: warning(.previousRunDied, .critical),
                         restartableConfigPath: "/tmp/star_temp_seq/config.json")

        viewModel.restartAbandonedRun()

        XCTAssertFalse(viewModel.showWarningAlert)
        XCTAssertNil(viewModel.restartableRunConfigPath)
        viewModel.eraserTask?.cancel()

        viewModel.report(warning: warning(.previousRunDied, .critical),
                         restartableConfigPath: "/tmp/star_temp_seq/config.json")
        XCTAssertFalse(viewModel.showWarningAlert,
                       "the report the user acted on must not come back")
    }

    /// And with nothing to restart it does nothing at all, rather than tearing the alert
    /// down as if it had.
    func testRestartingWithNothingToRestartLeavesTheAlertAlone() {
        let viewModel = ViewModel()
        viewModel.report(warning: warning(.memoryPressure, .critical))

        viewModel.restartAbandonedRun()

        XCTAssertTrue(viewModel.showWarningAlert)
    }

    /// From the marker to the alert: a run that can be restarted gets the button, and the
    /// text names neither its config nor a command to type.
    func testAStoppedRunsAlertOffersARestartAndNamesNoPath() throws {
        let directory = FileManager.default.temporaryDirectory
          .appendingPathComponent("warning-alert-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = directory.appendingPathComponent("config.json")
        try Data("{}".utf8).write(to: config)

        var marker = RunMarker(id: "x", client: "Star")
        marker.sequenceName = "seq"
        marker.resumeConfigPath = config.path
        let viewModel = ViewModel()
        viewModel.reportAbandonedRuns([marker], turnOffGPUMerge: {})

        XCTAssertTrue(viewModel.showWarningAlert)
        XCTAssertEqual(viewModel.restartableRunConfigPath, config.path)
        XCTAssertFalse(viewModel.warningAlertText.contains(config.path),
                       viewModel.warningAlertText)
        XCTAssertFalse(viewModel.warningAlertText.contains("star /"),
                       viewModel.warningAlertText)
    }

    /// Restart Now above OK, OK the default, and the window left alone: a system alert would
    /// put the two side by side, so this report has a sheet of its own.
    func testTheStoppedRunSheetStacksRestartNowAboveOK() throws {
        let viewModel = ViewModel()
        let host = NSHostingView(rootView: ContentView().environment(viewModel))
        host.sizingOptions = [.minSize, .intrinsicContentSize, .maxSize]

        let window = OffDisplayWindow(contentRect: OffDisplayWindow.farAway,
                                      styleMask: [.titled, .resizable, .closable],
                                      backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        window.contentView = host
        window.setContentSize(NSSize(width: 900, height: 600))
        // A SwiftUI sheet, unlike an alert, is only presented over a window that is ordered in.
        window.orderFront(nil)
        settle()
        OffDisplayWindow.assertNothingShowsOnADisplay()
        let quietMinimum = window.contentMinSize
        let quietContent = host.frame.size

        viewModel.report(warning: warning(.previousRunDied, .critical),
                         restartableConfigPath: "/tmp/star_temp_seq/config.json")
        XCTAssertTrue(viewModel.showStoppedRunSheet)
        XCTAssertFalse(viewModel.showSystemWarningAlert)
        settle(1.0)
        OffDisplayWindow.assertNothingShowsOnADisplay()

        let content = try XCTUnwrap(window.attachedSheet?.contentView)
        let found = buttons(in: content)
        XCTAssertEqual(found.count, 2)
        let restart = try XCTUnwrap(found.first { $0.keyEquivalent != "\r" })
        let ok = try XCTUnwrap(found.first { $0.keyEquivalent == "\r" })
        let restartFrame = restart.convert(restart.bounds, to: nil)
        let okFrame = ok.convert(ok.bounds, to: nil)
        // Window coordinates: y grows upwards.
        XCTAssertGreaterThan(restartFrame.midY, okFrame.midY,
                             "Restart Now \(restartFrame) must be above OK \(okFrame)")
        XCTAssertEqual(restartFrame.midX, okFrame.midX, accuracy: 1)
        XCTAssertEqual(window.contentMinSize, quietMinimum)
        XCTAssertEqual(host.frame.size, quietContent)

        ok.performClick(nil)
        settle()
        XCTAssertFalse(viewModel.showWarningAlert, "OK is the one with the return key")
        XCTAssertNil(viewModel.restartableRunConfigPath)
    }

    /// A machine warning that arrives over the stopped run's sheet takes its place, and the
    /// sheet going away must not count as the user having read it.
    func testTheSheetGivingWayDoesNotAcknowledgeTheNextWarning() {
        let viewModel = ViewModel()
        viewModel.report(warning: warning(.previousRunDied, .critical),
                         restartableConfigPath: "/tmp/star_temp_seq/config.json")
        viewModel.report(warning: warning(.memoryPressure, .critical))
        viewModel.showStoppedRunSheet = false

        XCTAssertTrue(viewModel.showSystemWarningAlert)
    }

    // MARK: - the alert's text

    /// The system alert takes one body string, so the suggestion has to be folded into it —
    /// and kept as its own paragraph, because unlike an error there is usually something the
    /// user can do.
    func testTheSuggestionBecomesItsOwnParagraph() {
        let viewModel = ViewModel()
        viewModel.report(warning: StarWarning(kind: .memoryPressure,
                                              severity: .critical,
                                              message: "the message",
                                              suggestion: "the suggestion"))

        XCTAssertEqual(viewModel.warningAlertText, "the message\n\nthe suggestion")
    }

    func testAConditionWithNothingToSuggestIsJustTheMessage() {
        let viewModel = ViewModel()
        viewModel.report(warning: StarWarning(kind: .previousRunDied,
                                              severity: .critical,
                                              message: "the message"))

        XCTAssertEqual(viewModel.warningAlertText, "the message")
    }

    // MARK: - helpers

    private func buttons(in view: NSView) -> [NSButton] {
        if let button = view as? NSButton { return [button] }
        return view.subviews.flatMap { buttons(in: $0) }
    }

    private func warning(_ kind: StarWarning.Kind,
                         _ severity: StarWarning.Severity) -> StarWarning
    {
        StarWarning(kind: kind,
                    severity: severity,
                    message: "star is holding 101311MB, and this is a sentence long enough to "
                      + "wrap several times over in a narrow column, which is what made the "
                      + "hand-drawn panel's height unbounded.",
                    suggestion: "Closing other applications now may let this run finish. If it "
                      + "is stopped, resume it and add --keypoint-divisor 1.5 to use less "
                      + "memory.")
    }

    /// SwiftUI pushes size changes onto the window on its own update cycle, not inside the
    /// call that changed the state, so the run loop has to turn before the window can be
    /// asked what it now believes.
    private func settle(_ seconds: TimeInterval = 0.4) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    /// Waits out a (deliberately tiny) `bannerLifetime`, polling rather than sleeping a fixed
    /// time so the test is not racing the expiry task on a loaded machine.
    private func waitForBannerToClear(_ viewModel: ViewModel,
                                      within seconds: TimeInterval = 3) async {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline, viewModel.bannerWarning != nil {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}
