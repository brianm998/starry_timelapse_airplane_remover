import XCTest
@testable import StarCore

/// `StarShutdown` turns an interruption into an orderly stop.  Most of it can only be
/// exercised by actually signalling a process — `performShutdown` ends in `exit`, so it cannot
/// be called from a test at all — and that end-to-end behaviour is verified by signalling the
/// real `star` binary rather than from here.
///
/// What is worth testing in-process is the part that is pure decision-making, plus the
/// invariant that installing must never be the thing that breaks a client: it happens during
/// startup in all three, and a throw or a hang there would take down every run.
final class StarShutdownTests: XCTestCase {

    /// Which signals count as "stop cleanly".
    ///
    /// Pinned because the set is a judgement, not an obvious default, and each one is here for
    /// a stated reason: SIGINT is Ctrl-C, SIGTERM is `kill` and — the case that made this
    /// urgent — the desktop client's `Process.destroy()`, and SIGHUP is a closed terminal
    /// window, which is an ordinary way to abandon a long cli run.
    ///
    /// Notably absent: SIGQUIT, which conventionally means "dump core", so honouring it as a
    /// clean stop would take away the one thing its user wanted.
    func testTheHandledSignalsAreTheThreeCleanStopSignals() throws {
        #if os(Windows)
        throw XCTSkip("no signals on Windows")
        #else
        XCTAssertEqual(Set(StarShutdown.handledSignals), [SIGINT, SIGTERM, SIGHUP])
        XCTAssertFalse(StarShutdown.handledSignals.contains(SIGQUIT),
                       "SIGQUIT asks for a core dump; treating it as a clean stop discards it")
        // These belong to the crash handler, which reports them and re-raises. Treating any of
        // them as a clean stop would swallow a crash.
        XCTAssertFalse(StarShutdown.handledSignals.contains(SIGSEGV))
        XCTAssertFalse(StarShutdown.handledSignals.contains(SIGABRT))
        #endif
    }

    /// The two signal mechanisms must not overlap: whatever `StarShutdown` claims, the crash
    /// handler does not, and vice versa. An overlap would mean one silently replacing the
    /// other's disposition depending on install order — a crash reported as a clean stop, or
    /// a Ctrl-C reported as a crash.
    func testTheCleanStopSignalsDoNotOverlapTheFatalOnes() throws {
        #if os(Windows)
        throw XCTSkip("no signals on Windows")
        #else
        let fatal: Set<Int32> = [SIGSEGV, SIGILL, SIGFPE, SIGABRT, SIGBUS, SIGTRAP]
        XCTAssertTrue(Set(StarShutdown.handledSignals).isDisjoint(with: fatal))
        #endif
    }

    /// Installing is done during startup in all three clients, so it has to be safe to call
    /// more than once and safe to call when nothing else has been set up yet.
    func testInstallingIsIdempotentAndDoesNotThrow() {
        StarShutdown.install(clientName: "test", quiet: true)
        StarShutdown.install(clientName: "test", quiet: true)
        StarShutdown.install(clientName: "test", quiet: true)
        // Nothing is shutting down just because handlers exist.
        XCTAssertFalse(StarShutdown.isShuttingDown)
    }

    /// The watchdog is the difference between an interrupt that always works and one that
    /// works most of the time.  It has to be long enough that the ordinary path (cancel
    /// operations, drain the log queue) finishes first, and short enough that a user who has
    /// pressed Ctrl-C is not left wondering.
    func testTheGracePeriodIsShortButNotInstant() {
        XCTAssertGreaterThanOrEqual(StarShutdown.gracePeriod, 1)
        XCTAssertLessThanOrEqual(StarShutdown.gracePeriod, 15)
    }
}
