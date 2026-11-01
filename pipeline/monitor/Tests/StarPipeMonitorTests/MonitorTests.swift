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
    }

    func testEveryTicketIsInAKnownGroupAndStagesCarryTheirLockWait() throws {
        let s = try Self.snapshot()
        for t in s.tickets { XCTAssertTrue(s.groups.contains(t.group), "\(t.number) is in \(t.group)") }
        let running = try XCTUnwrap(s.tickets.first { $0.group == "running" })
        XCTAssertEqual(running.stages.first?.stage, "develop")
        XCTAssertEqual(running.stages.first?.lockWaitS, 0)
        XCTAssertNil(running.stages.first?.ended)
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
