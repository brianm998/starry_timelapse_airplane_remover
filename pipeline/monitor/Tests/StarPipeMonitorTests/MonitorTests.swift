import Foundation
import XCTest
@testable import StarPipeMonitorCore

final class FixtureTests: XCTestCase {
    static func fixture() throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "snapshot", withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    static func snapshot() throws -> Snapshot { try JSONDecoder().decode(Snapshot.self, from: fixture()) }

    func testTheDaemonsRecordedSnapshotDecodes() throws {
        let s = try Self.snapshot()
        XCTAssertEqual(s.tickets.count, 6)
        XCTAssertEqual(s.groups, ["needs_you", "running", "waiting", "queued", "landed_today", "failed"])
        XCTAssertEqual(s.repo, "brianm998/starry_timelapse_airplane_remover")
        XCTAssertEqual(s.runtime.behindDevelop, 2)
        XCTAssertEqual(s.heavy.holders.first?.cmd, "swift test --package-path StarCore")
        XCTAssertEqual(s.heavy.queue.first?.enqueuedAt, 2.0)
        XCTAssertEqual(s.develop.gate, ["linux": "success"])
        XCTAssertEqual(s.develop.knownRed, 1)
        XCTAssertEqual(s.interventionsWeek, ["answer": 1])
        XCTAssertEqual(s.nightly?.reds, 1)
        XCTAssertEqual(s.nightly?.line, "Sat 03:00 · aaaaaaaa · 1 red")
        XCTAssertEqual(s.nightly?.running, false)
        XCTAssertNil(s.usagePauseUntil)
        XCTAssertEqual(s.usageWindows, UsageWindows(fiveHour: UsageWindow(utilization: 0.1, resetsAt: 3600),
                                                    sevenDay: UsageWindow(utilization: 0.24, resetsAt: 90000)))
    }

    func testLandingQueueSectionShowsTheBatchTheAbandonedBatchAndTheSlowFlag() throws {
        var s = try Self.snapshot()
        XCTAssertEqual(s.landing.batch, BatchInfo(number: 2, phase: "ci", ageS: 90, members: [3], prNumber: 12, slow: false))
        XCTAssertEqual(s.landing.lastAbandoned?.reason, "develop moved")
        XCTAssertEqual(Overview.landingLines(s.landing).map(\.text),
                       ["batch 2: ci · age 1m · #3", "batch 1 abandoned 1m ago: develop moved"])
        XCTAssertEqual(Overview.landingLines(s.landing).map(\.slow), [false, false])

        s.landing.batch = BatchInfo(number: 8, phase: "building", ageS: 11 * 60, members: [59, 76], prNumber: nil, slow: true)
        s.landing.lastAbandoned = AbandonedBatch(number: 7, state: "abandoned", reason: "develop moved with overlapping changes",
                                                 agoS: 18 * 60)
        XCTAssertEqual(Overview.landingLines(s.landing).map(\.text),
                       ["batch 8: building · age 11m · #59 #76 · SLOW",
                        "batch 7 abandoned 18m ago: develop moved with overlapping changes"])
        XCTAssertEqual(Overview.landingLines(s.landing).map(\.slow), [true, false])

        s.landing.batch = nil
        s.landing.lastAbandoned = nil
        s.landing.nextBatchInS = 45
        XCTAssertEqual(Overview.landingLines(s.landing).map(\.text), ["no batch yet: the next one starts in 45s"])
        s.landing.nextBatchInS = nil
        XCTAssertEqual(Overview.landingLines(s.landing), [])
        XCTAssertEqual(Overview.landingLines(nil), [])
    }

    func testSnapshotDecodesMaxActive() throws {
        XCTAssertEqual(try Self.snapshot().maxActive, 2)
    }

    func testSnapshotDecodesMuted() throws {
        XCTAssertEqual(try Self.snapshot().muted, false)
    }

    func testOverviewGroupsActiveSessionsByModelAndOrdersTheLandingQueue() throws {
        let base = try XCTUnwrap(try Self.snapshot().tickets.first)
        func ticket(_ n: Int, _ state: String, model: String?, stage: String? = nil) -> TicketSnap {
            var t = base
            t.number = n; t.state = state; t.model = model
            t.stages = stage.map { [StageSnap(stage: $0, attempt: 1, model: model ?? "", started: 1, ended: nil, lockWaitS: 0, outcome: nil)] } ?? []
            return t
        }
        let tickets = [ticket(9, "developing", model: "opus", stage: "develop"), ticket(3, "exploring", model: "sonnet", stage: "explore"),
                       ticket(5, "review", model: "opus", stage: "review"), ticket(6, "ci", model: nil), ticket(2, "landing", model: nil),
                       ticket(4, "ready", model: nil), ticket(7, "queued", model: nil), ticket(8, "ci", model: nil)]
        let groups = Overview.activeModels(tickets)
        XCTAssertEqual(groups.map(\.model), ["opus", "sonnet"])
        XCTAssertEqual(groups[0].sessions.map(\.ticket.number), [5, 9])
        XCTAssertEqual(groups[0].sessions.map(\.stage), ["review", "develop"])
        XCTAssertEqual(Overview.landingQueue(tickets).map(\.number), [6, 8, 2, 4])
    }

    func testTopBarCountsBucketTicketStates() throws {
        // the labels are fixed text, not derived from a snapshot, so the "—" placeholder tiles read the same
        XCTAssertEqual(Overview.topBarBuckets.map(\.label), ["need you", "queued", "exploring", "developing", "testing", "review", "landing"])
        let base = try XCTUnwrap(try Self.snapshot().tickets.first)
        func ticket(_ n: Int, _ state: String) -> TicketSnap {
            var t = base
            t.number = n; t.state = state
            return t
        }
        let live = ["queued", "exploring", "developing", "verifying", "review", "ready", "ci", "landing", "needs-input", "paused"]
        let terminal = ["landed", "failed", "closed", "cancelled"]
        // two needs-input tickets and two ci tickets to tell a count from a presence check
        let states = live + terminal + ["needs-input", "ci"]
        let counts = Overview.topBarCounts(states.enumerated().map { ticket($0.offset + 1, $0.element) })
        XCTAssertEqual(counts.map(\.label), ["need you", "queued", "exploring", "developing", "testing", "review", "landing"])
        XCTAssertEqual(counts.map(\.count), [2, 1, 1, 1, 1, 1, 4])
        // every live state but paused is in exactly one bucket; paused and terminal states in none
        for state in live + terminal {
            let hits = counts.filter { $0.states.contains(state) }.count
            XCTAssertEqual(hits, live.contains(state) && state != "paused" ? 1 : 0, state)
        }
        XCTAssertEqual(Overview.topBarCounts([]).map(\.count), [0, 0, 0, 0, 0, 0, 0])
    }

    func testTopBarHelpDescribesEachBucket() {
        for bucket in Overview.topBarBuckets {
            XCTAssertFalse(bucket.help.isEmpty, bucket.label)
            // the tooltip is the stage text followed by the daemon states, and is more than the bare state list
            XCTAssertTrue(bucket.tooltip.hasPrefix(bucket.help), bucket.label)
            XCTAssertTrue(bucket.tooltip.hasSuffix("Counts tickets in: " + bucket.states.joined(separator: ", ")), bucket.label)
            XCTAssertGreaterThan(bucket.help.count, 40, bucket.label)
        }
        XCTAssertTrue(Overview.topBarBuckets[6].help.contains("ci"))
        XCTAssertTrue(Overview.topBarBuckets[4].tooltip.contains("verifying"))
    }

    func testTopBarHelpSameWithoutSnapshot() throws {
        // the live tiles (StageCount) and the no-snapshot tiles (buckets) show the same tooltip
        let base = try XCTUnwrap(try Self.snapshot().tickets.first)
        var t = base
        t.state = "developing"
        for tickets in [[], [t]] {
            XCTAssertEqual(Overview.topBarCounts(tickets).map(\.tooltip), Overview.topBarBuckets.map(\.tooltip))
        }
    }

    func testTopBarTileEmphasis() throws {
        let base = try XCTUnwrap(try Self.snapshot().tickets.first)
        func tickets(_ states: [String]) -> [TicketSnap] {
            states.enumerated().map { var t = base; t.number = $0.offset + 1; t.state = $0.element; return t }
        }
        func emphases(_ states: [String]) -> [Overview.TileEmphasis] { Overview.topBarCounts(tickets(states)).map(\.emphasis) }
        // nothing in flight: every tile is idle, needs-input included
        XCTAssertEqual(emphases([]), Array(repeating: .idle, count: 7))
        // a needs-input ticket is the only attention tile; the other non-zero buckets are active
        XCTAssertEqual(emphases(["needs-input", "queued", "landing"]),
                       [.attention, .active, .idle, .idle, .idle, .idle, .active])
        // non-zero buckets other than needs-input never draw attention
        XCTAssertEqual(emphases(["developing", "review"]), [.idle, .idle, .idle, .active, .idle, .active, .idle])
    }

    func testStatusRows() throws {
        let base = try Self.snapshot()
        func rows(_ s: Snapshot?, _ c: Connection = .live, update: Bool = false) -> [Overview.StatusRow] {
            Overview.statusRows(snapshot: s, connection: c, updateAvailable: update, rebuildCommand: "make app",
                                timeZone: TimeZone(identifier: "UTC")!)
        }
        let r = rows(base)
        XCTAssertEqual(r.map(\.label).prefix(4), ["Daemon", "Heavy lock", "Landing", "develop"])
        XCTAssertEqual(r.first { $0.label == "Daemon" }?.value, "up, \(base.runtime.sha)" + (base.runtime.behindDevelop > 0 ? ", behind develop by \(base.runtime.behindDevelop)" : ""))
        XCTAssertEqual(r.first { $0.label == "Daemon" }?.severity, .ok)
        XCTAssertEqual(r.first { $0.label == "Landing" }?.value, "running")
        XCTAssertTrue(r.first { $0.label == "develop" }!.value.hasPrefix("pr-gate"))
        XCTAssertEqual(r.first { $0.label == "Last nightly" }?.value, base.nightly?.line ?? "none yet")
        for gone in ["Usage limit", "Monitor update", "Paused"] { XCTAssertNil(r.first { $0.label == gone }, gone) }
        XCTAssertEqual(Overview.attentionWords(r), [])

        var s = base
        s.landing.stopLine = "pr-gate red"; s.landing.paused = true
        s.pause = "owner pause"; s.usagePauseUntil = "0"
        let bad = rows(s, .down("refused"), update: true)
        XCTAssertEqual(bad.first { $0.label == "Daemon" }?.value, "down: refused")
        XCTAssertEqual(bad.first { $0.label == "Daemon" }?.severity, .bad)
        XCTAssertEqual(bad.first { $0.label == "Landing" }?.value, "stopped: pr-gate red")
        XCTAssertEqual(bad.first { $0.label == "Landing" }?.severity, .warn)
        XCTAssertEqual(bad.first { $0.label == "develop" }?.severity, .bad)
        XCTAssertEqual(bad.first { $0.label == "Monitor update" }?.value, "Update available — make app")
        XCTAssertEqual(bad.first { $0.label == "Paused" }?.value, "owner pause")
        XCTAssertTrue(bad.first { $0.label == "Usage limit" }!.value.hasPrefix("model stages wait until "))
        XCTAssertEqual(Overview.attentionWords(bad),
                       ["Daemon down", "Landing paused", "develop red", "Usage limit", "Update available", "Paused"])

        let connecting = rows(nil, .connecting)
        XCTAssertEqual(connecting.map(\.value).prefix(4), ["connecting…", "—", "—", "—"])
        XCTAssertEqual(connecting.first { $0.label == "Last nightly" }?.value, "none yet")
        XCTAssertEqual(Overview.attentionWords(connecting), [])
    }

    func testEveryTicketIsInAKnownGroupAndStagesCarryTheirLockWait() throws {
        let s = try Self.snapshot()
        for t in s.tickets { XCTAssertTrue(s.groups.contains(t.group), "\(t.number) is in \(t.group)") }
        let running = try XCTUnwrap(s.tickets.first { $0.group == "running" })
        XCTAssertEqual(running.stages.first?.stage, "develop")
        XCTAssertEqual(running.stages.first?.lockWaitS, 0)
        XCTAssertNil(running.stages.first?.ended)
    }

    // sidebar search ---------------------------------------------------------------------------------------------------
    private static func searchTickets() throws -> [TicketSnap] {
        let base = try XCTUnwrap(try snapshot().tickets.first)
        func t(_ n: Int, title: String, branch: String?, body: String) -> TicketSnap {
            var t = base
            t.number = n; t.title = title; t.branch = branch; t.body = body
            return t
        }
        return [t(123, title: "Fix the Horizon", branch: "pipe/123-horizon", body: "the mask is wrong"),
                t(45, title: "Search bar", branch: nil, body: "mentions ZEBRA crossings"),
                t(7, title: "Unrelated", branch: "pipe/7-misc", body: "")]
    }

    func testSearchQueryMatchesCheckedFields() throws {
        let tickets = try Self.searchTickets()
        func hits(_ q: String) -> [Int] { TicketSearch(query: q).filter(tickets).map(\.number) }
        XCTAssertEqual(hits(""), [123, 45, 7])
        XCTAssertEqual(hits("horizon"), [123])          // title, case-insensitive (and the branch)
        XCTAssertEqual(hits("#123"), [123])             // number with hash
        XCTAssertEqual(hits("123"), [123])              // number without hash
        XCTAssertEqual(hits("pipe/7"), [7])             // branch
        XCTAssertEqual(hits("zebra"), [45])             // body, case-insensitive
        XCTAssertEqual(hits("nothing like it"), [])
    }

    func testSearchFieldTogglesAndNoFields() throws {
        let tickets = try Self.searchTickets()
        func hits(_ q: String, name: Bool = true, title: Bool = true, body: Bool = true) -> [Int] {
            TicketSearch(query: q, matchName: name, matchTitle: title, matchBody: body).filter(tickets).map(\.number)
        }
        XCTAssertEqual(hits("mask", body: false), [])
        XCTAssertEqual(hits("mask", name: false, title: false), [123])
        XCTAssertEqual(hits("Search", title: false), [])
        XCTAssertEqual(hits("123", name: false), [])
        XCTAssertEqual(hits("pipe/", name: false, title: false, body: true), [])
        XCTAssertEqual(hits("horizon", name: false, body: false), [123])
        XCTAssertEqual(hits("horizon", name: false, title: false, body: false), [])
        XCTAssertEqual(hits("", name: false, title: false, body: false), [123, 45, 7])  // empty query still shows all
    }

    func testSearchClear() throws {
        let tickets = try Self.searchTickets()
        var search = TicketSearch(query: "zebra", matchName: true, matchTitle: false, matchBody: true)
        XCTAssertEqual(search.filter(tickets).map(\.number), [45])
        search.clear()
        XCTAssertEqual(search.query, "")
        XCTAssertFalse(search.isActive)
        XCTAssertEqual(search.matchTitle, false)  // toggles survive
        XCTAssertEqual(search.filter(tickets).count, tickets.count)
    }

    func testTicketSnapDecodesBody() throws {
        let s = try Self.snapshot()
        XCTAssertTrue(try XCTUnwrap(s.tickets.first).body.contains("## Goal"))
        // a daemon that predates the field: drop the key and decode again
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Self.fixture()) as? [String: Any])
        var rows = try XCTUnwrap(object["tickets"] as? [[String: Any]])
        for i in rows.indices { rows[i].removeValue(forKey: "body") }
        object["tickets"] = rows
        let old = try JSONDecoder().decode(Snapshot.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(old.tickets.map(\.body), Array(repeating: "", count: old.tickets.count))
    }

    @MainActor
    func testSearchDoesNotAffectCounts() throws {
        let store = MonitorStore()
        store.apply(try FixtureTests.snapshot())
        let before = (store.needsYouCount, Overview.topBarCounts(store.snapshot!.tickets).map(\.count))
        store.selected = 5
        store.search.query = "no ticket contains this text"
        XCTAssertTrue(store.searchHidesEverything)
        XCTAssertEqual(store.snapshot!.groups.flatMap { store.visibleTickets(in: $0) }.count, 0)
        XCTAssertEqual(store.needsYouCount, before.0)
        XCTAssertEqual(Overview.topBarCounts(store.snapshot!.tickets).map(\.count), before.1)
        XCTAssertEqual(store.tickets(in: "needs_you").count, 1)
        XCTAssertEqual(store.selected, 5)  // a filtered-out selection stays selected
        store.search.clear()
        XCTAssertFalse(store.searchHidesEverything)
        XCTAssertEqual(store.visibleTickets(in: "needs_you").count, 1)
    }
}

extension FixtureTests {
    func testTicketsDecodeTheRunningStagesModel() throws {
        let s = try Self.snapshot()
        let running = try XCTUnwrap(s.tickets.first { $0.group == "running" })
        XCTAssertEqual(running.model, "opus")
        XCTAssertEqual(running.stages.first?.model, "opus")
        XCTAssertNil(try XCTUnwrap(s.tickets.first { $0.group == "queued" }).model)
        // a snapshot from a daemon that predates the field still decodes
        let old = try JSONSerialization.jsonObject(with: Self.fixture()) as! [String: Any]
        var tickets = old["tickets"] as! [[String: Any]]
        tickets[0].removeValue(forKey: "model")
        var stripped = old
        stripped["tickets"] = tickets
        let decoded = try JSONDecoder().decode(Snapshot.self, from: JSONSerialization.data(withJSONObject: stripped))
        XCTAssertNil(decoded.tickets[0].model)
    }
}

final class DetailTests: XCTestCase {
    func testARealTicketDetailDecodes() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "detail", withExtension: "json", subdirectory: "Fixtures"))
        let d = try JSONDecoder().decode(TicketDetail.self, from: Data(contentsOf: url))
        XCTAssertEqual(d.number, 28)
        XCTAssertFalse(try XCTUnwrap(d.plan).summary.isEmpty)
        XCTAssertEqual(d.plan?.acceptance.first?.id, "A1")
        XCTAssertEqual(d.checks.first?.checkId, "t0:diff-check")
        XCTAssertEqual(d.checks.first?.result, "pass")
        XCTAssertNil(d.question)
        XCTAssertEqual(d.blockers, [BlockerRef(number: 27, title: "Processing Frames dialog: remember the window size")])
        XCTAssertEqual(d.heldRetry, "retry from ci when unblocked")
    }

    func testADetailWithoutBlockersFromAnOlderDaemonDecodesToNone() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "detail", withExtension: "json", subdirectory: "Fixtures"))
        var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        raw["blockers"] = nil
        raw["held_retry"] = nil
        let d = try JSONDecoder().decode(TicketDetail.self, from: JSONSerialization.data(withJSONObject: raw))
        XCTAssertEqual(d.blockers, [])
        XCTAssertNil(d.heldRetry)
        XCTAssertEqual(d.number, 28)
    }
}

final class BlockerLinksTests: XCTestCase {
    let repo = "brianm998/starry_timelapse_airplane_remover"

    func testBlockerLinksBuildIssueURLsAndRowLabels() throws {
        XCTAssertEqual(BlockerLinks.issueURL(repo: repo, number: 84)?.absoluteString,
                       "https://github.com/brianm998/starry_timelapse_airplane_remover/issues/84")
        XCTAssertNil(BlockerLinks.issueURL(repo: "", number: 84))
        let row = try XCTUnwrap(BlockerLinks.row(activity: "queued: #84, #85", blockedBy: [84, 85], repo: repo))
        XCTAssertEqual(row.prefix, "queued:")
        XCTAssertEqual(row.links.map(\.label), ["#84", "#85"])
        XCTAssertEqual(row.links.map(\.url.absoluteString), [84, 85].map { "https://github.com/\(repo)/issues/\($0)" })
        XCTAssertNil(BlockerLinks.row(activity: "queued", blockedBy: [], repo: repo), "an unblocked row is plain text")
        XCTAssertNil(BlockerLinks.row(activity: "developing · attempt 1/3 · 4m", blockedBy: [84], repo: repo))
        XCTAssertNil(BlockerLinks.row(activity: "queued: #84", blockedBy: [84], repo: ""), "no repo, no links")
    }

    func testDetailRowsListEachBlockerAndAreEmptyWithNone() {
        let rows = BlockerLinks.detailRows(blockers: [BlockerRef(number: 84, title: "first"), BlockerRef(number: 85, title: "")],
                                           repo: repo)
        XCTAssertEqual(rows.map(\.label), ["#84", "#85"])
        XCTAssertEqual(rows.map(\.title), ["first", ""])
        XCTAssertEqual(rows.map(\.url.absoluteString), [84, 85].map { "https://github.com/\(repo)/issues/\($0)" })
        XCTAssertEqual(BlockerLinks.detailRows(blockers: [], repo: repo), [])
    }

}

@MainActor
final class StoreTests: XCTestCase {
    func testTheMenuBarCountMatchesTheNeedsYouGroup() throws {
        let store = MonitorStore()
        XCTAssertEqual(store.needsYouCount, 0)
        store.apply(try FixtureTests.snapshot())
        XCTAssertEqual(store.needsYouCount, 1)
        XCTAssertEqual(store.needsYouCount, store.tickets(in: "needs_you").count)
        XCTAssertEqual(store.tickets(in: "needs_you").first?.question, "Which of the two?")
        XCTAssertEqual(store.connection, .live)
    }

    func testTheBadgeShowsWhenDevelopIsRedOrTheDaemonIsDown() throws {
        let store = MonitorStore()
        var s = try FixtureTests.snapshot()
        store.apply(s)
        XCTAssertFalse(store.needsAttention)
        s.landing.stopLine = "pr-gate/linux"
        store.apply(s)
        XCTAssertTrue(store.developRed)
        XCTAssertTrue(store.needsAttention)
    }

    func testASelectionThatDisappearsIsCleared() throws {
        let store = MonitorStore()
        var s = try FixtureTests.snapshot()
        store.apply(s)
        store.selected = 5
        XCTAssertEqual(store.selectedTicket?.number, 5)
        s.tickets.removeAll { $0.number == 5 }
        store.apply(s)
        XCTAssertNil(store.selected)
    }

    /// Fixture ticket 3 blocked by a ticket (6) and a non-ticket issue (99).
    private func blockedSnapshot() throws -> Snapshot {
        var s = try FixtureTests.snapshot()
        let i = try XCTUnwrap(s.tickets.firstIndex { $0.number == 3 })
        s.tickets[i].blockedBy = [6, 99]
        return s
    }

    func testSelectingBlockerShowsItInPanel() throws {
        let store = MonitorStore()
        store.apply(try blockedSnapshot())
        store.selectIssue(6)
        XCTAssertEqual(store.selectedTicket?.number, 6)
        XCTAssertNil(store.selectedIssue)
        store.selectIssue(99, title: "outside")
        XCTAssertNil(store.selectedTicket)
        XCTAssertEqual(store.selectedIssue?.number, 99)
        XCTAssertEqual(store.selectedIssue?.title, "outside")
    }

    func testSnapshotKeepsSelectedBlockerNotInTickets() throws {
        let store = MonitorStore()
        store.apply(try blockedSnapshot())
        store.selectIssue(99, title: "outside")
        store.apply(try blockedSnapshot())
        XCTAssertEqual(store.selected, 99)
        XCTAssertNil(store.selectedTicket)
        XCTAssertEqual(store.selectedIssue?.title, "outside")
        store.apply(try FixtureTests.snapshot())   // nothing is blocked by 99 any more
        XCTAssertNil(store.selected)
    }

    func testBlockerSelectionIsInHistory() throws {
        let store = MonitorStore()
        store.apply(try blockedSnapshot())
        store.selectIssue(99)
        store.selected = 6
        store.goBack()
        XCTAssertEqual(store.selected, 99)
        store.goForward()
        XCTAssertEqual(store.selected, 6)
    }

    func testShowOverviewClearsTheSelectionAndDetail() async throws {
        let store = MonitorStore()
        store.apply(try FixtureTests.snapshot())
        store.selected = 5
        XCTAssertEqual(store.selectedTicket?.number, 5)
        store.showOverview()
        XCTAssertNil(store.selected)
        XCTAssertNil(store.selectedTicket)
        XCTAssertNil(store.detail)
        XCTAssertTrue(store.logLines.isEmpty)
    }

    func testNavigationHistoryRecordsEachViewChangeOnce() throws {
        let store = MonitorStore()
        store.apply(try FixtureTests.snapshot())
        XCTAssertFalse(store.canGoBack)
        store.selected = 5
        store.selected = 5            // already showing: nothing recorded
        store.selected = 3
        store.showOverview()
        store.showOverview()
        store.goBack()
        XCTAssertEqual(store.selected, 3)
        store.goBack()
        XCTAssertEqual(store.selected, 5)
        store.goBack()
        XCTAssertNil(store.selected)
        XCTAssertFalse(store.canGoBack)
        XCTAssertTrue(store.canGoForward)
    }

    func testBackThenNewSelectionDropsForwardHistory() throws {
        let store = MonitorStore()
        store.apply(try FixtureTests.snapshot())
        store.selected = 5
        store.selected = 3
        store.goBack()
        XCTAssertEqual(store.selected, 5)
        XCTAssertTrue(store.canGoForward)
        store.selected = 6
        XCTAssertFalse(store.canGoForward)
        store.goBack()
        XCTAssertEqual(store.selected, 5)
        store.goForward()
        XCTAssertEqual(store.selected, 6)
        XCTAssertFalse(store.canGoForward)
    }

    func testBackSkipsTicketsThatLeftTheSnapshot() throws {
        let store = MonitorStore()
        var s = try FixtureTests.snapshot()
        store.apply(s)
        store.selected = 5
        store.selected = 3
        store.selected = 6
        s.tickets.removeAll { $0.number == 3 }
        store.apply(s)
        store.goBack()
        XCTAssertEqual(store.selected, 5)   // 9 skipped
        // a snapshot-driven reset is not a navigation
        s.tickets.removeAll { $0.number == 5 }
        store.apply(s)
        XCTAssertNil(store.selected)
        XCTAssertFalse(store.canGoBack)     // only dead entries remain behind the Overview
        XCTAssertTrue(store.canGoForward)
        store.goForward()
        XCTAssertEqual(store.selected, 6)
    }

    func testNavigationHistoryIsBounded() throws {
        let store = MonitorStore()
        store.apply(try FixtureTests.snapshot())
        for i in 0..<(MonitorStore.historyLimit * 2) { store.selected = i.isMultiple(of: 2) ? 5 : 3 }
        var steps = 0
        while store.canGoBack { store.goBack(); steps += 1 }
        XCTAssertEqual(steps, MonitorStore.historyLimit - 1)
    }

    func testOnlyTheLastFiveChangesAreKept() {
        let store = MonitorStore()
        for i in 1...8 {
            store.apply(event: ServerEvent(id: i, ticket: i, kind: "state", data: ["state": "developing"], at: Double(i)))
        }
        XCTAssertEqual(store.recentChanges.map(\.id), [8, 7, 6, 5, 4])
        XCTAssertEqual(store.recentChanges.first?.text, "#8 developing")
        store.apply(event: ServerEvent(id: 9, ticket: 1, kind: "stage-start", data: [:], at: 9))
        XCTAssertEqual(store.recentChanges.first?.id, 8, "only state changes are news")
    }

    func testAlertsAreDeliveredAsTheSnapshotsChange() throws {
        let store = MonitorStore()
        var seen: [Alert] = []
        store.onAlert = { seen.append($0) }
        var s = try FixtureTests.snapshot()
        s.tickets[0].group = "queued"  // ticket 1 was waiting on the owner; start from a world where nothing needs you
        store.apply(s)
        XCTAssertTrue(seen.isEmpty, "the first snapshot is a baseline")
        s.tickets[0].group = "needs_you"
        s.tickets[0].question = "Which of the two?"
        store.apply(s)
        XCTAssertEqual(seen.map(\.kind), [.needsInput])
        XCTAssertEqual(seen.first?.body, "Which of the two?")
        store.apply(s)
        XCTAssertEqual(seen.count, 1, "an unchanged snapshot says nothing new")
    }
}

final class AlertTests: XCTestCase {
    func testStopTheLineAndFailuresAlertOnce() throws {
        let old = try FixtureTests.snapshot()
        var new = old
        new.landing.stopLine = "pr-gate/linux"
        new.tickets[2].group = "failed"
        let kinds = Alerts.diff(old: old, new: new).map(\.kind)
        XCTAssertEqual(Set(kinds), [.developRed, .failed])
        XCTAssertTrue(Alerts.diff(old: new, new: new).isEmpty)
    }

    func testQuietHoursHoldEverythingExceptPages() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        func at(_ h: Int) -> Date { cal.date(from: DateComponents(year: 2026, month: 10, day: 31, hour: h))! }
        XCTAssertTrue(Alerts.isQuiet(at(23), calendar: cal))
        XCTAssertTrue(Alerts.isQuiet(at(3), calendar: cal))
        XCTAssertFalse(Alerts.isQuiet(at(7), calendar: cal))
        XCTAssertFalse(Alerts.isQuiet(at(12), calendar: cal))
        let page = Alert(kind: .needsInput, ticket: 1, title: "t", body: "b")
        let news = Alert(kind: .failed, ticket: 1, title: "t", body: "b")
        XCTAssertTrue(Alerts.shouldDeliver(page, at: at(23), calendar: cal))
        XCTAssertFalse(Alerts.shouldDeliver(news, at: at(23), calendar: cal))
        XCTAssertTrue(Alerts.shouldDeliver(news, at: at(12), calendar: cal))
    }
}

final class SSETests: XCTestCase {
    func testFramingIdsAndKeepalives() {
        var p = SSEParser()
        XCTAssertNil(p.feed(line: ": keepalive"))
        XCTAssertNil(p.feed(line: ""))
        XCTAssertNil(p.feed(line: "id: 7"))
        XCTAssertNil(p.feed(line: #"data: {"id": 7, "at": 12.5, "ticket": 28, "kind": "state", "data": {"state": "ci", "reason": null}}"#))
        let event = p.feed(line: "")
        XCTAssertEqual(event, ServerEvent(id: 7, ticket: 28, kind: "state", data: ["state": "ci", "reason": ""], at: 12.5))
        XCTAssertNil(p.feed(line: ""), "a blank line with no data is not an event")
    }

    func testAnEventWithoutATicketAndAMalformedOne() {
        var p = SSEParser()
        _ = p.feed(line: #"data: {"id": 3, "at": 1, "ticket": null, "kind": "alert", "data": {}}"#)
        XCTAssertEqual(p.feed(line: "")?.ticket, nil)
        _ = p.feed(line: "data: not json")
        XCTAssertNil(p.feed(line: ""))
    }
}

final class ConfigTests: XCTestCase {
    func makeHome(token: String?, toml: String? = nil) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("starpipe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let token { try token.write(to: dir.appendingPathComponent("api.token"), atomically: true, encoding: .utf8) }
        if let toml { try toml.write(to: dir.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8) }
        return dir
    }

    func testTheTokenAndPortComeFromTheStateDirectory() throws {
        let home = try makeHome(token: "secret\n", toml: "owner = \"x\"\napi_port = 5555\n")
        let cfg = try APIConfig.load(environment: ["STARPIPE_HOME": home.path])
        XCTAssertEqual(cfg.token, "secret")
        XCTAssertEqual(cfg.baseURL.absoluteString, "http://127.0.0.1:5555")
    }

    func testTheDefaultPortAndTheEnvironmentOverride() throws {
        let home = try makeHome(token: "t")
        XCTAssertEqual(try APIConfig.load(environment: ["STARPIPE_HOME": home.path]).baseURL.port, 47231)
        XCTAssertEqual(try APIConfig.load(environment: ["STARPIPE_HOME": home.path, "STARPIPE_API_PORT": "1234"]).baseURL.port, 1234)
    }

    func testAMissingTokenSaysWhere() throws {
        let home = try makeHome(token: nil)
        XCTAssertThrowsError(try APIConfig.load(environment: ["STARPIPE_HOME": home.path])) { error in
            XCTAssertEqual(error as? APIConfig.LoadError, .noToken(home.appendingPathComponent("api.token").path))
        }
    }
}

final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, body) = Self.handler!(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class ClientTests: XCTestCase {
    func client() -> APIClient {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubProtocol.self]
        return APIClient(config: APIConfig(baseURL: URL(string: "http://127.0.0.1:1")!, token: "tok"), session: URLSession(configuration: cfg))
    }

    func testTheSnapshotIsFetchedWithTheBearerToken() async throws {
        let body = try FixtureTests.fixture()
        StubProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
            XCTAssertEqual(request.url?.path, "/v1/snapshot")
            return (200, body)
        }
        let s = try await client().snapshot()
        XCTAssertEqual(s.tickets.count, 6)
    }

    func testAnAnswerPostsTheTextToTheTicket() async throws {
        StubProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/v1/tickets/28/answer")
            let sent = request.httpBodyStream.flatMap { stream -> Data in
                stream.open()
                defer { stream.close() }
                var data = Data()
                var buf = [UInt8](repeating: 0, count: 1024)
                while stream.hasBytesAvailable {
                    let n = stream.read(&buf, maxLength: buf.count)
                    if n <= 0 { break }
                    data.append(buf, count: n)
                }
                return data
            } ?? request.httpBody ?? Data()
            XCTAssertTrue(String(decoding: sent, as: UTF8.self).contains("the first"))
            return (200, Data(#"{"result": "ok"}"#.utf8))
        }
        try await client().answer(28, text: "the first")
    }

    func testErrorsAreReportedWithTheirStatus() async {
        StubProtocol.handler = { _ in (409, Data("no open question".utf8)) }
        do {
            try await client().answer(1, text: "x")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? APIError, .status(409, "no open question"))
        }
    }
}

final class IssueLinksTests: XCTestCase {
    func testLinksSplitOnAnyWhitespaceDropEmptiesAndCollapseDuplicates() {
        let a = "https://github.com/brianm998/starry_timelapse_airplane_remover/issues/8"
        let b = "https://github.com/brianm998/starry_timelapse_airplane_remover/issues/9"
        let c = "https://github.com/brianm998/starry_timelapse_airplane_remover/issues/10"
        let text = "  \(a)\r\n\n\n\(b)\t\(a) \(c)\n\t \n\(b)\n"
        XCTAssertEqual(IssueLinks.parse(text), [a, b, c])
        XCTAssertEqual(IssueLinks.parse(" \n\t\r\n "), [])
        XCTAssertEqual(IssueLinks.parse(""), [])
    }

    func testTheEnqueueRequestCarriesOnlyNonDefaultModelChoices() {
        let body = EnqueueRequest.body(numbers: [8, 9], choices: ["develop": "sonnet", "review": "Default", "fix": "opus", "explore": ""])
        XCTAssertEqual(body["numbers"] as? [Int], [8, 9])
        XCTAssertEqual(body["models"] as? [String: String], ["develop": "sonnet", "fix": "opus"])

        let none = EnqueueRequest.body(numbers: [8], choices: ["develop": "Default"])
        XCTAssertEqual(none["numbers"] as? [Int], [8])
        XCTAssertNil(none["models"])
        XCTAssertNil(EnqueueRequest.body(numbers: [8], choices: [:])["models"])
    }

    func testAResolvedIssueDecodesTheAllowedModelsAndStages() throws {
        let json = #"{"number": 8, "title": "Fix", "state": "open", "queued": false, "models": ["opus", "sonnet", "haiku", "fable"], "stages": ["explore", "ci_fix"]}"#
        let issue = try JSONDecoder().decode(ResolvedIssue.self, from: Data(json.utf8))
        XCTAssertEqual(issue.models, ["opus", "sonnet", "haiku", "fable"])
        XCTAssertEqual(issue.stages, ["explore", "ci_fix"])

        let old = #"{"number": 8, "title": "Fix", "state": "open", "queued": true}"#
        let older = try JSONDecoder().decode(ResolvedIssue.self, from: Data(old.utf8))
        XCTAssertNil(older.models)
        XCTAssertNil(older.stages)
    }
}

final class FontScaleTests: XCTestCase {
    func testBiggerAndSmallerStepAndClampAndResetReturnsToOne() {
        XCTAssertEqual(FontScale.default, 1.0)
        XCTAssertEqual(FontScale.bigger(1.0), 1.1, accuracy: 1e-9)
        XCTAssertEqual(FontScale.smaller(1.0), 0.9, accuracy: 1e-9)

        // Repeated steps do not drift: ten steps up from 1.0 is exactly 2.0, and it stops there.
        var scale = FontScale.default
        for _ in 0..<10 { scale = FontScale.bigger(scale) }
        XCTAssertEqual(scale, 2.0, accuracy: 1e-9)
        XCTAssertEqual(FontScale.bigger(scale), FontScale.maximum)
        for _ in 0..<30 { scale = FontScale.smaller(scale) }
        XCTAssertEqual(scale, FontScale.minimum, accuracy: 1e-9)
        XCTAssertEqual(FontScale.smaller(scale), FontScale.minimum)

        // A bad stored value falls back to the default; out-of-range values clamp.
        XCTAssertEqual(FontScale.clamped(.nan), 1.0)
        XCTAssertEqual(FontScale.clamped(-3), 1.0)
        XCTAssertEqual(FontScale.clamped(0), 1.0)
        XCTAssertEqual(FontScale.clamped(9), FontScale.maximum)
        XCTAssertEqual(FontScale.clamped(0.1), FontScale.minimum)
    }
}

@MainActor
final class UpdateTests: XCTestCase {
    private func client() -> APIClient {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubProtocol.self]
        return APIClient(config: APIConfig(baseURL: URL(string: "http://127.0.0.1:1")!, token: "tok"), session: URLSession(configuration: cfg))
    }

    private func answer(_ json: String) {
        StubProtocol.handler = { _ in (200, Data(json.utf8)) }
    }

    /// A store whose "remembered sha" lives in a local box, like UserDefaults does in the app.
    private func makeStore(sourceSHA: String?, remembered: Box = Box()) -> (MonitorStore, Box, Notices) {
        let notices = Notices()
        let store = MonitorStore(client: client(), sourceSHA: sourceSHA,
                                 lastNotifiedUpdate: { remembered.sha }, setLastNotifiedUpdate: { remembered.sha = $0 })
        store.onUpdate = { notices.alerts.append($0) }
        return (store, remembered, notices)
    }

    final class Box { var sha: String? }
    final class Notices { var alerts: [Alert] = [] }

    func testNotifiesOncePerLatestShaWhenBehind() async throws {
        let (store, remembered, notices) = makeStore(sourceSHA: "aaaa111")
        answer(#"{"behind": 3, "latest": "bbbb222"}"#)
        await store.checkForUpdate()
        await store.checkForUpdate()  // the hourly check finds the same version: no second notice
        XCTAssertEqual(notices.alerts.count, 1)
        XCTAssertEqual(notices.alerts.first?.title, "Pipeline monitor update available")
        XCTAssertEqual(notices.alerts.first?.body, "3 new commits — run `make -C pipeline/monitor app`")
        XCTAssertEqual(remembered.sha, "bbbb222")
        XCTAssertTrue(store.updateAvailable)

        answer(#"{"behind": 4, "latest": "cccc333"}"#)  // develop moved on: announce again
        await store.checkForUpdate()
        XCTAssertEqual(notices.alerts.count, 2)
        XCTAssertEqual(remembered.sha, "cccc333")

        // a relaunch remembers what was announced
        let (relaunched, _, again) = makeStore(sourceSHA: "aaaa111", remembered: remembered)
        await relaunched.checkForUpdate()
        XCTAssertTrue(again.alerts.isEmpty)
        XCTAssertTrue(relaunched.updateAvailable)
    }

    func testOneNewCommitIsSingular() {
        let n = MonitorUpdates.notification(for: MonitorUpdateInfo(behind: 1, latest: "x"), lastNotified: nil)
        XCTAssertEqual(n?.alert.body, "1 new commit — run `make -C pipeline/monitor app`")
    }

    func testNeverNotifiesWhenUpToDateOrUnstamped() async throws {
        let (current, _, currentNotices) = makeStore(sourceSHA: "aaaa111")
        answer(#"{"behind": 0, "latest": "aaaa111"}"#)
        await current.checkForUpdate()
        XCTAssertTrue(currentNotices.alerts.isEmpty)
        XCTAssertFalse(current.updateAvailable)

        let (unknown, _, unknownNotices) = makeStore(sourceSHA: "aaaa111")
        answer(#"{"behind": null, "latest": "bbbb222"}"#)
        await unknown.checkForUpdate()
        XCTAssertTrue(unknownNotices.alerts.isEmpty)
        XCTAssertFalse(unknown.updateAvailable)

        // an unstamped build (`swift run`) does not even ask, so it can never report an update
        for sha in [nil, ""] {
            let (unstamped, remembered, notices) = makeStore(sourceSHA: sha)
            StubProtocol.handler = { _ in
                XCTFail("an unstamped build must not call the daemon")
                return (200, Data(#"{"behind": 5, "latest": "bbbb222"}"#.utf8))
            }
            await unstamped.checkForUpdate()
            XCTAssertTrue(notices.alerts.isEmpty)
            XCTAssertNil(remembered.sha)
            XCTAssertFalse(unstamped.updateAvailable)
        }
    }

    func testAnUpdateNoticeIsNotHeldByQuietHours() {
        let alert = Alert(kind: .monitorUpdate, ticket: nil, title: "t", body: "b")
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let night = cal.date(from: DateComponents(year: 2026, month: 10, day: 31, hour: 23))!
        XCTAssertTrue(Alerts.isQuiet(night, calendar: cal))
        XCTAssertTrue(Alerts.shouldDeliver(alert, at: night, calendar: cal))
    }

    func testTheClientAsksForTheStampedShaAndDecodesBehindAndNull() async throws {
        StubProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
            XCTAssertEqual(request.url?.path, "/v1/monitor-update")
            XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "abc123")
            return (200, Data(#"{"behind": 2, "latest": "def456"}"#.utf8))
        }
        let info = try await client().monitorUpdate(sha: "abc123")
        XCTAssertEqual(info, MonitorUpdateInfo(behind: 2, latest: "def456"))

        answer(#"{"behind": null, "latest": null}"#)
        let unknown = try await client().monitorUpdate(sha: "abc123")
        XCTAssertEqual(unknown, MonitorUpdateInfo(behind: nil, latest: nil))
    }
}

final class UsageLimitTextTests: XCTestCase {
    let zone = TimeZone(identifier: "America/Los_Angeles")!
    /// Wednesday 2026-11-04 12:00 in Los Angeles (UTC-8).
    let now = Date(timeIntervalSince1970: 1_793_822_400)

    func window(_ utilization: Double, in seconds: TimeInterval) -> UsageWindow {
        UsageWindow(utilization: utilization, resetsAt: now.timeIntervalSince1970 + seconds)
    }

    func line(_ kind: UsageLimitText.Kind, _ w: UsageWindow?) -> (text: String, level: UsageLimitText.Level) {
        UsageLimitText.line(kind: kind, window: w, now: now, timeZone: zone)
    }

    func testUsageLineFormat() {
        XCTAssertEqual(line(.fiveHour, window(0.10, in: 4 * 3600)).text, "5 hour: 10% resets in 4 hours (4pm)")
        XCTAssertEqual(line(.fiveHour, window(0.10, in: 3600)).text, "5 hour: 10% resets in 1 hour (1pm)")
        XCTAssertEqual(line(.fiveHour, window(0.42, in: 2 * 3600 + 40 * 60)).text, "5 hour: 42% resets in 3 hours (2:40pm)")
        XCTAssertEqual(line(.fiveHour, window(0.5, in: 30 * 60)).text, "5 hour: 50% resets in 30 min (12:30pm)")
        XCTAssertEqual(line(.fiveHour, window(0.5, in: 22 * 3600 + 30 * 60)).text, "5 hour: 50% resets in 23 hours (10:30am)")
        XCTAssertEqual(line(.fiveHour, window(0.5, in: 12 * 3600)).text, "5 hour: 50% resets in 12 hours (12am)")
        // Friday 10:00 in Los Angeles is one day and 22 hours after Wednesday noon.
        XCTAssertEqual(line(.weekly, window(0.24, in: (24 + 22) * 3600)).text, "weekly: 24% resets at 10am friday")
        XCTAssertEqual(line(.weekly, window(0.24, in: (24 + 22) * 3600 + 30 * 60)).text, "weekly: 24% resets at 10:30am friday")
    }

    func testUsageLineColourBands() {
        let levels = [0.79, 0.80, 0.89, 0.90].map { line(.fiveHour, window($0, in: 3600)).level }
        XCTAssertEqual(levels, [.ok, .warn, .warn, .critical])
        XCTAssertEqual(line(.weekly, window(0.0, in: 3600)).level, .ok)
        XCTAssertEqual(line(.weekly, window(1.0, in: 3600)).level, .critical)
    }

    func testUsageLineStaleOrMissing() {
        XCTAssertEqual(line(.fiveHour, nil).text, "5 hour: —")
        XCTAssertEqual(line(.weekly, nil).text, "weekly: —")
        XCTAssertEqual(line(.fiveHour, nil).level, .unknown)
        XCTAssertEqual(line(.weekly, window(0.95, in: -1)).text, "weekly: —")  // reset already: the old 95% no longer applies
        XCTAssertEqual(line(.weekly, window(0.95, in: -1)).level, .unknown)
        XCTAssertEqual(line(.fiveHour, window(0.95, in: 0)).level, .unknown)
    }
}

@MainActor
final class ProposalTests: XCTestCase {
    private func client() -> APIClient {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubProtocol.self]
        return APIClient(config: APIConfig(baseURL: URL(string: "http://127.0.0.1:1")!, token: "tok"), session: URLSession(configuration: cfg))
    }

    /// The recorded snapshot with `proposals` removed, as an older daemon sends it.
    private func olderDaemonsSnapshot() throws -> Snapshot {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: FixtureTests.fixture()) as? [String: Any])
        json.removeValue(forKey: "proposals")
        return try JSONDecoder().decode(Snapshot.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private func withProposals(_ list: [ProposalSnap]) throws -> Snapshot {
        var s = try FixtureTests.snapshot()
        s.proposalList = list
        return s
    }

    func testProposalsDecodeAndOldSnapshotsStillDo() throws {
        XCTAssertEqual(try FixtureTests.snapshot().proposals,
                       [ProposalSnap(number: 31, title: "Show the retry budget", by: "review agent")])
        let old = try olderDaemonsSnapshot()
        XCTAssertEqual(old.proposals, [])
        XCTAssertEqual(old.tickets.count, 6)
    }

    func testProposalRowsComeFromTheSnapshot() throws {
        let store = MonitorStore()
        XCTAssertEqual(store.proposals, [])
        store.apply(try FixtureTests.snapshot())
        XCTAssertEqual(store.proposals.map(\.number), [31])
        XCTAssertEqual(store.proposals.first?.title, "Show the retry budget")
        XCTAssertEqual(store.proposals.first?.by, "review agent")
        store.apply(try olderDaemonsSnapshot())
        XCTAssertEqual(store.proposals, [])
    }

    func testSelectingAProposalIsShowableAndClearsWhenItGoes() throws {
        let store = MonitorStore()
        store.apply(try FixtureTests.snapshot())
        store.selected = 31
        XCTAssertEqual(store.selectedProposal?.title, "Show the retry budget")
        XCTAssertNil(store.selectedTicket)
        XCTAssertNil(store.selectedIssue, "a proposal has its own pane, not the generic issue one")
        store.apply(try FixtureTests.snapshot())   // survives a refresh while it exists
        XCTAssertEqual(store.selected, 31)
        store.apply(try olderDaemonsSnapshot())    // gone: approved, rejected or closed elsewhere
        XCTAssertNil(store.selected)
        XCTAssertNil(store.selectedProposal)
    }

    func testApproveAndRejectPostThenRefresh() async throws {
        let fixture = try FixtureTests.fixture()
        final class Seen: @unchecked Sendable { var requests: [(String, String, String)] = [] }
        let seen = Seen()
        @Sendable func body(_ r: URLRequest) -> String {
            let data = r.httpBodyStream.flatMap { stream -> Data in
                stream.open()
                defer { stream.close() }
                var data = Data()
                var buf = [UInt8](repeating: 0, count: 1024)
                while stream.hasBytesAvailable {
                    let n = stream.read(&buf, maxLength: buf.count)
                    if n <= 0 { break }
                    data.append(buf, count: n)
                }
                return data
            } ?? r.httpBody ?? Data()
            return String(decoding: data, as: UTF8.self)
        }
        StubProtocol.handler = { request in
            seen.requests.append((request.httpMethod ?? "", request.url?.path ?? "", body(request)))
            return request.url?.path == "/v1/snapshot" ? (200, fixture) : (200, Data(#"{"result": "ok"}"#.utf8))
        }
        let store = MonitorStore(client: client())
        await store.approve(31, priority: "p1")
        XCTAssertNil(store.lastError)
        XCTAssertEqual(seen.requests.first?.1, "/v1/proposals/31/approve")
        XCTAssertEqual(seen.requests.first?.0, "POST")
        XCTAssertTrue(seen.requests.first?.2.contains("\"p1\"") ?? false)
        XCTAssertEqual(store.snapshot?.proposals.map(\.number), [31], "the snapshot is refreshed after the post")
        await store.reject(31, reason: "not now")
        let reject = try XCTUnwrap(seen.requests.first { $0.1 == "/v1/proposals/31/reject" })
        XCTAssertTrue(reject.2.contains("not now"))

        StubProtocol.handler = { request in
            request.url?.path == "/v1/snapshot" ? (200, fixture) : (409, Data("3 tickets are already open for the pipeline".utf8))
        }
        await store.approve(31)
        XCTAssertEqual(store.lastError, APIError.status(409, "3 tickets are already open for the pipeline").localizedDescription)
        XCTAssertTrue(store.lastError?.contains("already open") ?? false)
    }
}
