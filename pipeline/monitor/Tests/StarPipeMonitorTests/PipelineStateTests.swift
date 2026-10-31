import Foundation
import XCTest
@testable import StarPipeMonitorCore

final class PipelineStateTests: XCTestCase {
    /// The fixture's snapshot with every ticket moved to `group` (none at all when `group` is nil).
    private func snapshot(allIn group: String? = "queued") throws -> Snapshot {
        var s = try FixtureTests.snapshot()
        s.landing.stopLine = nil
        if let group {
            for i in s.tickets.indices { s.tickets[i].group = group }
        } else {
            s.tickets = []
        }
        return s
    }

    private func state(_ s: Snapshot?, daemonDown: Bool = false) -> PipelineState {
        PipelineState.of(snapshot: s, daemonDown: daemonDown)
    }

    func testEachRedCauseIsRed() throws {
        var needsYou = try snapshot()
        needsYou.tickets[0].group = "needs_you"
        XCTAssertEqual(state(needsYou), .red)

        var failed = try snapshot()
        failed.tickets[0].group = "failed"
        XCTAssertEqual(state(failed), .red)

        var stopped = try snapshot()
        stopped.landing.stopLine = "pr-gate/linux"
        XCTAssertEqual(state(stopped), .red)

        XCTAssertEqual(state(try snapshot(), daemonDown: true), .red)
        XCTAssertEqual(state(nil, daemonDown: true), .red)
    }

    func testRunningOrWaitingTicketsAreGreen() throws {
        for group in ["running", "waiting"] {
            var s = try snapshot()
            s.tickets[0].group = group
            XCTAssertEqual(state(s), .green, group)
        }
    }

    func testAUsageLimitPauseWithTicketsInFlightStaysGreen() throws {
        for group in ["running", "waiting"] {
            var s = try snapshot()
            s.usagePauseUntil = "2026-10-31T18:00:00Z"
            s.tickets[0].group = group
            XCTAssertEqual(state(s), .green, group)
        }
    }

    func testNothingActiveIsGreyAndRedTakesPrecedenceOverGreen() throws {
        XCTAssertEqual(state(try snapshot()), .grey)
        XCTAssertEqual(state(try snapshot(allIn: nil)), .grey)
        var landed = try snapshot(allIn: "landed_today")
        landed.tickets[0].group = "queued"
        XCTAssertEqual(state(landed), .grey)
        XCTAssertEqual(state(nil), .grey, "before the first snapshot")

        var mixed = try snapshot()
        mixed.tickets[0].group = "running"
        mixed.tickets[1].group = "waiting"
        XCTAssertEqual(state(mixed), .green)
        mixed.tickets[2].group = "needs_you"
        XCTAssertEqual(state(mixed), .red)
        mixed.tickets[2].group = "failed"
        XCTAssertEqual(state(mixed), .red)
        mixed.tickets[2].group = "queued"
        mixed.landing.stopLine = "pr-gate/linux"
        XCTAssertEqual(state(mixed), .red)
    }

    @MainActor
    func testTheStoreExposesTheStateIncludingDaemonDown() async throws {
        let store = MonitorStore()
        XCTAssertEqual(store.pipelineState, .grey)
        var s = try snapshot()
        s.tickets[0].group = "running"
        store.apply(s)
        XCTAssertEqual(store.pipelineState, .green)
        s.landing.stopLine = "pr-gate/linux"
        store.apply(s)
        XCTAssertEqual(store.pipelineState, .red)
        s.landing.stopLine = nil
        store.apply(s)
        XCTAssertEqual(store.pipelineState, .green)

        // a daemon that does not answer turns even a green pipeline red (nothing listens on port 1)
        let dead = APIConfig(baseURL: try XCTUnwrap(URL(string: "http://127.0.0.1:1")), token: "t")
        let down = MonitorStore(client: APIClient(config: dead))
        down.apply(s)
        XCTAssertEqual(down.pipelineState, .green)
        await down.refresh()
        XCTAssertTrue(down.daemonDown)
        XCTAssertEqual(down.pipelineState, .red)
    }
}
