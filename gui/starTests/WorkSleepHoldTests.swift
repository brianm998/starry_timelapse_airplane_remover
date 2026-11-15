import XCTest
import AVFoundation
import SwiftUI
import Observation
import StarCore
import StarCppBridge
// The app target is named `Star`, not `star` — the lowercase name belongs to the .xcodeproj
// and to this test target.  TEST_HOST points at Star.app, so this is what links.
@testable import Star


/// The machine may sleep with a sequence open and nothing running; it is held off from the start of a run, a render or an
/// extraction to its end.  The Kotlin client's `WorkSleepGuardTest` pins the same behaviour.
@MainActor
final class WorkSleepHoldTests: XCTestCase {
    private final class FakeBlocker: SleepBlocking {
        var calls: [String] = []
        func begin(light: Bool) { calls.append(light ? "begin(light)" : "begin") }
        func end() { calls.append("end") }
    }

    func testNothingRunningNeverBegins() {
        let blocker = FakeBlocker()
        let hold = WorkSleepHold(blocker: blocker)
        hold.set(.run, active: false)
        hold.set(.render, active: false)
        hold.set(.extraction, active: false)
        XCTAssertEqual(blocker.calls, [])
        XCTAssertFalse(hold.isHolding)
    }

    func testEachKindOfWorkHoldsFromStartToEnd() {
        let blocker = FakeBlocker()
        let hold = WorkSleepHold(blocker: blocker)
        for kind in [WorkSleepHold.Kind.run, .render, .extraction] {
            hold.set(kind, active: true)
            XCTAssertTrue(hold.isHolding, "\(kind) starts the hold")
            hold.set(kind, active: false)
            XCTAssertFalse(hold.isHolding, "\(kind) ending lets go")
        }
        XCTAssertEqual(blocker.calls, ["begin", "end", "begin", "end", "begin", "end"])
    }

    func testOverlappingWorkEndsOnlyWhenTheLastEnds() {
        let blocker = FakeBlocker()
        let hold = WorkSleepHold(blocker: blocker)
        hold.set(.run, active: true)
        hold.set(.render, active: true)
        hold.set(.run, active: false)
        XCTAssertEqual(blocker.calls, ["begin"])
        hold.set(.render, active: false)
        XCTAssertEqual(blocker.calls, ["begin", "end"])
    }

    func testReleaseEndsHeldBlocker() {
        let blocker = FakeBlocker()
        let hold = WorkSleepHold(blocker: blocker)
        hold.release()
        XCTAssertEqual(blocker.calls, [], "nothing held, nothing to end")
        hold.set(.run, active: true)
        hold.release()
        XCTAssertEqual(blocker.calls, ["begin", "end"])
        hold.set(.run, active: false)
        XCTAssertEqual(blocker.calls, ["begin", "end"], "already let go")
    }

    func testLightProfileIsPassedToBegin() {
        let blocker = FakeBlocker()
        var light = true
        let hold = WorkSleepHold(blocker: blocker, light: { light })
        hold.set(.run, active: true)
        hold.set(.run, active: false)
        light = false
        hold.set(.run, active: true)
        XCTAssertEqual(blocker.calls, ["begin(light)", "end", "begin"])
    }
}
