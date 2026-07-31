import XCTest
import StarCore
import StarDaemonMessages
@testable import stard

/// `Dispatcher` is the daemon's routing table: it maps a method string to a handler, runs it in
/// its own Task, and keeps the Task around so `Processing.Cancel` can reach it.  Everything the
/// client can ask for arrives through `dispatch`.
///
/// These tests register their own handlers rather than the real ones, so routing can be checked
/// without standing up a session or touching an image.  The unknown-method error path is covered
/// end to end by `DaemonIntegrationTests.testUnknownMethodReturnsError`, which can observe the
/// error envelope on the wire — this file cannot, since the outbound stream is private to
/// `StdioTransport`, so it stops at what the routing itself decides.
final class DispatcherTests: XCTestCase {

    /// A transport that is constructed but never started: `send` yields into an `AsyncStream`
    /// nobody drains, so nothing is written to any file descriptor.  Calling `startWriter()`
    /// would write real frames to the test process's stdout.
    private func transport() -> StdioTransport { StdioTransport() }

    private func sessions() -> SessionManager {
        SessionManager(scratchRoot: NSTemporaryDirectory())
    }

    private func dispatcher() -> Dispatcher {
        Dispatcher(transport: transport(), sessions: sessions())
    }

    private func envelope(id: UInt64, method: String, payload: Data = Data()) -> Star_V1_Envelope {
        var env = Star_V1_Envelope()
        env.id = id
        env.kind = .request
        env.method = method
        env.payload = payload
        return env
    }

    /// Records what handlers were called with.  The handlers run in detached Tasks, so this is
    /// an actor and the tests poll it.
    private actor Calls {
        private(set) var entries: [(method: String, id: UInt64, payload: Data)] = []
        func record(_ method: String, _ id: UInt64, _ payload: Data) {
            entries.append((method, id, payload))
        }
        var count: Int { entries.count }
        var methods: [String] { entries.map(\.method) }
    }

    /// Handlers are dispatched onto their own Task, so a test has to wait for them rather than
    /// assume they have run by the time `dispatch` returns.
    private func waitForCalls(_ calls: Calls, toReach expected: Int) async throws {
        for _ in 0..<400 {
            if await calls.count >= expected { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let got = await calls.count
        XCTFail("expected \(expected) handler calls, saw \(got)")
    }

    // MARK: - routing

    func testARegisteredMethodReachesItsHandler() async throws {
        let dispatcher = self.dispatcher()
        let calls = Calls()

        await dispatcher.register(method: "Test.One") { id, payload, _ in
            await calls.record("Test.One", id, payload)
        }
        await dispatcher.dispatch(envelope: envelope(id: 7, method: "Test.One"))

        try await waitForCalls(calls, toReach: 1)
        let methods = await calls.methods
        XCTAssertEqual(methods, ["Test.One"])
    }

    /// The point of the table: one method must not run another's handler.
    func testEachMethodReachesOnlyItsOwnHandler() async throws {
        let dispatcher = self.dispatcher()
        let calls = Calls()

        for name in ["Test.One", "Test.Two", "Test.Three"] {
            await dispatcher.register(method: name) { id, payload, _ in
                await calls.record(name, id, payload)
            }
        }
        await dispatcher.dispatch(envelope: envelope(id: 1, method: "Test.Two"))

        try await waitForCalls(calls, toReach: 1)
        let methods = await calls.methods
        XCTAssertEqual(methods, ["Test.Two"], "dispatch ran the wrong handler")
    }

    /// The id has to arrive intact or the response would be attributed to the wrong request, and
    /// the payload is the request body — a handler that got someone else's bytes would decode
    /// garbage.
    func testTheIdAndPayloadArriveVerbatim() async throws {
        let dispatcher = self.dispatcher()
        let calls = Calls()
        let body = Data([0x00, 0xFF, 0x10, 0x42, 0x00])

        await dispatcher.register(method: "Test.Echo") { id, payload, _ in
            await calls.record("Test.Echo", id, payload)
        }
        await dispatcher.dispatch(envelope: envelope(id: 0xDEAD_BEEF,
                                                    method: "Test.Echo",
                                                    payload: body))

        try await waitForCalls(calls, toReach: 1)
        let entries = await calls.entries
        XCTAssertEqual(entries.first?.id, 0xDEAD_BEEF)
        XCTAssertEqual(entries.first?.payload, body, "the payload was altered in transit")
    }

    func testAnEmptyPayloadIsPassedThroughAsEmpty() async throws {
        let dispatcher = self.dispatcher()
        let calls = Calls()

        await dispatcher.register(method: "Test.Empty") { id, payload, _ in
            await calls.record("Test.Empty", id, payload)
        }
        await dispatcher.dispatch(envelope: envelope(id: 1, method: "Test.Empty"))

        try await waitForCalls(calls, toReach: 1)
        let entries = await calls.entries
        XCTAssertEqual(entries.first?.payload, Data())
    }

    /// Method strings are matched exactly — no trimming, no case folding.  A near miss has to
    /// take the unknown-method path rather than the closest handler.
    func testMethodMatchingIsExact() async throws {
        let dispatcher = self.dispatcher()
        let calls = Calls()

        await dispatcher.register(method: "Outlier.List") { id, payload, _ in
            await calls.record("Outlier.List", id, payload)
        }
        for nearMiss in ["outlier.list", "Outlier.list", "OutlierList", "Outlier.List ",
                         " Outlier.List", "Outlier.Lis"] {
            await dispatcher.dispatch(envelope: envelope(id: 1, method: nearMiss))
        }

        // give any mistakenly-dispatched handler time to run before asserting nothing did
        try await Task.sleep(nanoseconds: 50_000_000)
        let count = await calls.count
        XCTAssertEqual(count, 0, "a near miss reached the handler")
    }

    /// Registering the same method twice silently replaces, which is worth knowing: it is how a
    /// duplicated line in `registerAll` would lose one of the two without any warning.
    func testRegisteringAMethodTwiceKeepsOnlyTheLater() async throws {
        let dispatcher = self.dispatcher()
        let calls = Calls()

        await dispatcher.register(method: "Test.Dup") { id, payload, _ in
            await calls.record("first", id, payload)
        }
        await dispatcher.register(method: "Test.Dup") { id, payload, _ in
            await calls.record("second", id, payload)
        }
        await dispatcher.dispatch(envelope: envelope(id: 1, method: "Test.Dup"))

        try await waitForCalls(calls, toReach: 1)
        let methods = await calls.methods
        XCTAssertEqual(methods, ["second"], "the later registration should have won")
    }

    func testTheSameMethodCanBeDispatchedRepeatedly() async throws {
        let dispatcher = self.dispatcher()
        let calls = Calls()

        await dispatcher.register(method: "Test.Repeat") { id, payload, _ in
            await calls.record("Test.Repeat", id, payload)
        }
        for id in UInt64(1)...5 {
            await dispatcher.dispatch(envelope: envelope(id: id, method: "Test.Repeat"))
        }

        try await waitForCalls(calls, toReach: 5)
        let entries = await calls.entries
        XCTAssertEqual(entries.map(\.id).sorted(), [1, 2, 3, 4, 5],
                       "every request should have reached the handler with its own id")
    }

    // MARK: - cancellation

    /// `Processing.Cancel` works by cancelling the Task servicing a request id, so cancellation
    /// has to actually reach the running handler.
    func testCancellingAnIdReachesTheRunningHandler() async throws {
        let dispatcher = self.dispatcher()
        let started = Calls()
        let observed = Calls()

        await dispatcher.register(method: "Test.Long") { id, payload, _ in
            await started.record("started", id, payload)
            // run until cancelled
            for _ in 0..<400 {
                if Task.isCancelled { break }
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            if Task.isCancelled { await observed.record("cancelled", id, payload) }
        }

        await dispatcher.dispatch(envelope: envelope(id: 99, method: "Test.Long"))
        try await waitForCalls(started, toReach: 1)

        await dispatcher.cancel(id: 99)
        try await waitForCalls(observed, toReach: 1)

        let methods = await observed.methods
        XCTAssertEqual(methods, ["cancelled"], "the handler never saw its Task cancelled")
    }

    /// Cancelling one request must not disturb another that happens to be in flight.
    func testCancellingOneIdLeavesAnotherRunning() async throws {
        let dispatcher = self.dispatcher()
        let started = Calls()
        let cancelled = Calls()
        let finished = Calls()

        await dispatcher.register(method: "Test.Watch") { id, payload, _ in
            await started.record("started", id, payload)
            for _ in 0..<100 {
                if Task.isCancelled { await cancelled.record("cancelled", id, payload); return }
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            await finished.record("finished", id, payload)
        }

        await dispatcher.dispatch(envelope: envelope(id: 1, method: "Test.Watch"))
        await dispatcher.dispatch(envelope: envelope(id: 2, method: "Test.Watch"))
        try await waitForCalls(started, toReach: 2)

        await dispatcher.cancel(id: 1)
        try await waitForCalls(cancelled, toReach: 1)

        let cancelledIDs = await cancelled.entries.map(\.id)
        XCTAssertEqual(cancelledIDs, [1], "the wrong request was cancelled")
        let doneIDs = await finished.entries.map(\.id)
        XCTAssertFalse(doneIDs.contains(1))
    }

    /// A `Cancel` can arrive for a request that already finished, or one that was never seen —
    /// neither may trap.
    func testCancellingAnUnknownOrFinishedIdIsHarmless() async throws {
        let dispatcher = self.dispatcher()
        let calls = Calls()

        await dispatcher.register(method: "Test.Quick") { id, payload, _ in
            await calls.record("Test.Quick", id, payload)
        }
        await dispatcher.dispatch(envelope: envelope(id: 5, method: "Test.Quick"))
        try await waitForCalls(calls, toReach: 1)

        await dispatcher.cancel(id: 5)          // already done
        await dispatcher.cancel(id: 5)          // twice
        await dispatcher.cancel(id: 12345)      // never dispatched
        await dispatcher.taskCompleted(id: 999) // never dispatched

        // still able to serve requests afterwards
        await dispatcher.dispatch(envelope: envelope(id: 6, method: "Test.Quick"))
        try await waitForCalls(calls, toReach: 2)
    }

    /// `taskCompleted` is how a handler drops itself from the registry when it finishes.  A later
    /// cancel for that id then has nothing to do, which must still be safe.
    func testCompletingThenCancellingIsSafe() async throws {
        let dispatcher = self.dispatcher()
        let calls = Calls()

        await dispatcher.register(method: "Test.Done") { id, payload, t in
            await calls.record("Test.Done", id, payload)
        }
        await dispatcher.dispatch(envelope: envelope(id: 3, method: "Test.Done"))
        try await waitForCalls(calls, toReach: 1)

        await dispatcher.taskCompleted(id: 3)
        await dispatcher.cancel(id: 3)
    }

    // MARK: - the real registration table

    /// `registerAll` is a long list of hand-written method strings and `register` overwrites
    /// silently, so a duplicated or mistyped line would go unnoticed.  The table is checked by
    /// reading the source, because `handlers` is private and every real handler needs a session.
    ///
    /// This is the same approach the gui's `SettingsWiringTests` takes for the same reason.
    private func registerAllMethodNames() throws -> [String] {
        // daemon/Tests/StarDaemonTests/DispatcherTests.swift -> daemon/Sources/stard/Dispatcher.swift
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()        // StarDaemonTests
            .deletingLastPathComponent()        // Tests
            .deletingLastPathComponent()        // daemon
            .appendingPathComponent("Sources/stard/Dispatcher.swift")
        let text = try String(contentsOf: source, encoding: .utf8)

        let pattern = #"register\(method:\s*"([^"]+)""#
        let regex = try NSRegularExpression(pattern: pattern)
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range(at: 1)) }
    }

    func testTheRegistrationTableParsesAtAll() throws {
        let names = try registerAllMethodNames()
        XCTAssertGreaterThan(names.count, 30,
                             "only found \(names.count) registrations; the pattern has probably "
                             + "stopped matching Dispatcher.swift")
    }

    /// The failure this guards: two lines registering the same method, where the second silently
    /// replaces the first and one handler becomes unreachable.
    func testNoMethodIsRegisteredTwice() throws {
        let names = try registerAllMethodNames()
        let duplicates = Dictionary(grouping: names, by: { $0 }).filter { $0.value.count > 1 }.keys
        XCTAssertTrue(duplicates.isEmpty,
                      "these methods are registered more than once, so the earlier handler is "
                      + "unreachable: \(duplicates.sorted())")
    }

    /// Every method is `Category.Name`.  A missing dot or a stray space would be a method the
    /// client can never successfully call, and nothing else would report it.
    func testEveryMethodNameIsWellFormed() throws {
        for name in try registerAllMethodNames() {
            let parts = name.components(separatedBy: ".")
            XCTAssertEqual(parts.count, 2, "\(name) is not Category.Name")
            for part in parts {
                XCTAssertFalse(part.isEmpty, "\(name) has an empty component")
                XCTAssertEqual(part, part.trimmingCharacters(in: .whitespaces),
                               "\(name) has whitespace around a component")
                XCTAssertTrue(part.first?.isUppercase ?? false,
                              "\(name) does not use UpperCamelCase throughout")
            }
        }
    }

    /// The surface the Kotlin client codes against.  Listed explicitly so that removing or
    /// renaming a method — which would break that client silently, since the method is a plain
    /// string on both sides — has to be a deliberate edit here too.
    func testTheExpectedMethodSurfaceIsRegistered() throws {
        let expected: Set<String> = [
          "Daemon.Hello", "Daemon.Shutdown",
          "Session.OpenSequence", "Session.OpenConfig", "Session.OpenVideo",
          "Session.Close", "Session.List",
          "Sequence.GetConfig", "Sequence.UpdateConfig",
          "Frame.Get", "Frame.GetPreview", "Frame.GetOutlierLabelImage", "Frame.SetCleanMethod",
          "Outlier.List", "Outlier.SetDecisions", "Outlier.RenderFrame",
          "Outlier.ApplyDecisionTree", "Outlier.ApplyDecisionTreeAllFrames",
          "Outlier.SetDecisionsInArea", "Outlier.SetDecisionsOverlapping", "Outlier.ApplyAreaTool",
          "Processing.Start", "Processing.StreamProgress", "Processing.Cancel",
          "Processing.ReprocessFrames",
          "Export.RenderSequence", "Export.Video", "Export.GetVideoCapabilities",
          "Alignment.Get", "Alignment.GetSequence",
          "Horizon.SetReference", "Horizon.GetReference", "Horizon.ClearReference",
          "Horizon.Reprocess", "Horizon.GetOverlay", "Horizon.ComputeInBand", "Horizon.GetBest",
        ]
        let actual = Set(try registerAllMethodNames())

        XCTAssertTrue(expected.subtracting(actual).isEmpty,
                      "no longer registered: \(expected.subtracting(actual).sorted())")
        XCTAssertTrue(actual.subtracting(expected).isEmpty,
                      "newly registered and not yet listed here: "
                      + "\(actual.subtracting(expected).sorted())")
    }

    /// `registerAll` on a real dispatcher must not trap — it reads `sessions.scratchRoot` and
    /// builds every closure.
    func testRegisterAllCompletesOnARealDispatcher() async {
        let dispatcher = self.dispatcher()
        await dispatcher.registerAll()
    }
}
