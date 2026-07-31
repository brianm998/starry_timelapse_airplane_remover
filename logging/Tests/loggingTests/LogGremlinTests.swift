import XCTest
@testable import logging

/// `LogGremlin` is the actor that queues log lines and hands them to the registered handlers one
/// at a time.  `TaskWaiter` is the other half of shutdown — every standalone tool in the repo
/// ends with `TaskWaiter.shared.finish()` followed by `gremlin.finishLogging()`.
///
/// Most of these build the gremlin with `selfDraining: false` and step `logNext()` by hand.  A
/// production gremlin empties its own queue on a 1ms loop, so anything asserting on the queue
/// races that loop — the last test here is the one that deliberately uses a draining one, and it
/// polls rather than assuming a timing.
///
/// Note on style: every `await` is hoisted into a local before being asserted on.  XCTAssert's
/// arguments are non-async autoclosures, so `XCTAssertEqual(await x, y)` does not compile.
final class LogGremlinTests: XCTestCase {

    /// Records what it was handed, so a test can assert on the filtering.
    private final class Recording: LogHandler, @unchecked Sendable {
        let level: Log.Level
        private let lock = NSLock()
        private var _lines: [(String, Log.Level)] = []
        var lines: [(String, Log.Level)] {
            lock.lock(); defer { lock.unlock() }
            return _lines
        }

        init(at level: Log.Level) { self.level = level }

        func log(message: String, at fileLocation: String, with data: LogData?,
                 at logLevel: Log.Level, logTime: TimeInterval)
        {
            lock.lock(); defer { lock.unlock() }
            _lines.append((message, logLevel))
        }
    }

    // MARK: - the queue

    func testAFreshGremlinHasNothingQueued() async {
        let gremlin = LogGremlin(selfDraining: false)
        let count = await gremlin.pendingLogCount()
        let next = await gremlin.nextLog()
        XCTAssertEqual(count, 0)
        XCTAssertNil(next)
    }

    func testALoggedLineIsQueued() async {
        let gremlin = LogGremlin(selfDraining: false)
        await gremlin.log("something happened", at: .error, logTime: 0,
                          "Caller.swift", "doThing()", 42)
        let count = await gremlin.pendingLogCount()
        XCTAssertEqual(count, 1)
    }

    /// The gremlin exists to keep the output orderly, so the queue has to be first in first out.
    func testTheQueueIsFirstInFirstOut() async {
        let gremlin = LogGremlin(selfDraining: false)
        for i in 0..<5 {
            await gremlin.log("line \(i)", at: .error, logTime: 0, "F.swift", "f()", i)
        }

        var seen: [String] = []
        while let next = await gremlin.nextLog() { seen.append(next.message) }
        XCTAssertEqual(seen, (0..<5).map { "line \($0)" })
    }

    func testDrainingTheQueueEmptiesIt() async {
        let gremlin = LogGremlin(selfDraining: false)
        await gremlin.log("one", at: .error, logTime: 0, "F.swift", "f()", 1)
        _ = await gremlin.nextLog()

        let count = await gremlin.pendingLogCount()
        let next = await gremlin.nextLog()
        XCTAssertEqual(count, 0)
        XCTAssertNil(next)
    }

    // MARK: - the file location a caller gets attributed to

    /// The `#file` a log call captures is a full path, and only the last component belongs in the
    /// output — a whole build path per line would be unreadable.
    func testTheFileLocationIsTheBasenameAndLineNumber() async throws {
        let gremlin = LogGremlin(selfDraining: false)
        await gremlin.log("msg", at: .error, logTime: 0,
                          "/very/long/build/path/Caller.swift", "doThing()", 137)

        let queued = await gremlin.nextLog()
        let entry = try XCTUnwrap(queued)
        XCTAssertEqual(entry.fileLocation, "Caller.swift@137")
        XCTAssertFalse(entry.fileLocation.contains("/"), "the path should have been stripped")
    }

    func testAFilenameWithNoPathIsUsedAsIs() async throws {
        let gremlin = LogGremlin(selfDraining: false)
        await gremlin.log("msg", at: .warn, logTime: 0, "Bare.swift", "f()", 9)
        let queued = await gremlin.nextLog()
        let entry = try XCTUnwrap(queued)
        XCTAssertEqual(entry.fileLocation, "Bare.swift@9")
    }

    func testTheMessageLevelAndTimeAreCarriedThrough() async throws {
        let gremlin = LogGremlin(selfDraining: false)
        await gremlin.log("the message", at: .warn, logTime: 1234.5, "F.swift", "f()", 1)

        let queued = await gremlin.nextLog()
        let entry = try XCTUnwrap(queued)
        XCTAssertEqual(entry.message, "the message")
        XCTAssertEqual(entry.logLevel, .warn)
        XCTAssertEqual(entry.logTime, 1234.5)
        XCTAssertNil(entry.data, "no extra data was given")
    }

    func testExtraDataIsCarriedThrough() async throws {
        let gremlin = LogGremlin(selfDraining: false)
        await gremlin.log("with data", at: .error, logTime: 0,
                          extraData: StringLogData(with: "payload"),
                          "F.swift", "f()", 1)

        let queued = await gremlin.nextLog()
        let entry = try XCTUnwrap(queued)
        XCTAssertEqual(entry.data?.description, "payload")
    }

    // MARK: - handlers

    func testAHandlerCanBeRegisteredAndFetchedBack() async {
        let gremlin = LogGremlin(selfDraining: false)
        await gremlin.add(handler: Recording(at: .info), for: .console)

        let handlers = await gremlin.getHandlers()
        XCTAssertEqual(handlers.count, 1)
        XCTAssertNotNil(handlers[.console])
        XCTAssertEqual(handlers[.console]?.level, .info)
    }

    /// One handler per output, so registering a second console handler replaces the first rather
    /// than duplicating every line.
    func testASecondHandlerForTheSameOutputReplacesTheFirst() async {
        let gremlin = LogGremlin(selfDraining: false)
        await gremlin.add(handler: Recording(at: .info), for: .console)
        await gremlin.add(handler: Recording(at: .verbose), for: .console)

        let handlers = await gremlin.getHandlers()
        XCTAssertEqual(handlers.count, 1)
        XCTAssertEqual(handlers[.console]?.level, .verbose, "the later handler should have won")
    }

    /// The four outputs are independent — a file handler at `.debug` alongside a console handler
    /// at `.info` is the normal configuration.
    func testEachOutputHoldsItsOwnHandler() async {
        let gremlin = LogGremlin(selfDraining: false)
        await gremlin.add(handler: Recording(at: .info), for: .console)
        await gremlin.add(handler: Recording(at: .debug), for: .file)
        await gremlin.add(handler: Recording(at: .error), for: .alert)
        await gremlin.add(handler: Recording(at: .verbose), for: .gui)

        let handlers = await gremlin.getHandlers()
        XCTAssertEqual(handlers.count, 4)
        XCTAssertEqual(handlers[.console]?.level, .info)
        XCTAssertEqual(handlers[.file]?.level, .debug)
        XCTAssertEqual(handlers[.alert]?.level, .error)
        XCTAssertEqual(handlers[.gui]?.level, .verbose)
    }

    func testRemovingAHandlerLeavesTheOthersAlone() async {
        let gremlin = LogGremlin(selfDraining: false)
        await gremlin.add(handler: Recording(at: .info), for: .console)
        await gremlin.add(handler: Recording(at: .debug), for: .file)

        await gremlin.removeHandler(for: .console)

        let handlers = await gremlin.getHandlers()
        XCTAssertEqual(handlers.count, 1)
        XCTAssertNil(handlers[.console])
        XCTAssertNotNil(handlers[.file])
    }

    func testRemovingAHandlerThatWasNeverThereIsHarmless() async {
        let gremlin = LogGremlin(selfDraining: false)
        await gremlin.removeHandler(for: .gui)
        let handlers = await gremlin.getHandlers()
        XCTAssertTrue(handlers.isEmpty)
    }

    // MARK: - queueing does not depend on a handler existing

    /// A line logged before any handler is registered still queues, rather than being dropped —
    /// which is what lets startup logging survive until the handlers are installed.  The
    /// gremlin's own `minimumLogLevel` starts at `.error` (num 0) and its `add` only ever lowers
    /// it, so the guard in `log` never rejects anything in practice; the real filtering is
    /// per handler at drain time.
    func testLinesQueueEvenWithNoHandlersRegistered() async {
        let gremlin = LogGremlin(selfDraining: false)
        let handlers = await gremlin.getHandlers()
        XCTAssertTrue(handlers.isEmpty)

        for level in Log.Level.allCases {
            await gremlin.log("at \(level)", at: level, logTime: 0, "F.swift", "f()", 1)
        }
        let count = await gremlin.pendingLogCount()
        XCTAssertEqual(count, Log.Level.allCases.count, "every level should have queued")
    }

    /// Registering a noisy handler must not stop severe lines from queueing.  This is the
    /// direction the inverted `Log.Level` ordering makes easy to get wrong.
    func testAVerboseHandlerDoesNotStopErrorsFromQueueing() async {
        let gremlin = LogGremlin(selfDraining: false)
        await gremlin.add(handler: Recording(at: .verbose), for: .console)

        await gremlin.log("bad", at: .error, logTime: 0, "F.swift", "f()", 1)
        let count = await gremlin.pendingLogCount()
        XCTAssertEqual(count, 1)
    }

    // MARK: - instances are independent of the global gremlin

    /// `logNext` used to read the global `gremlin` rather than `self` on both of its lines, so a
    /// second instance drained the global queue and dispatched to the global's handlers instead
    /// of its own.  These pin that an instance only ever touches its own state.
    func testAnInstanceDeliversItsOwnLinesToItsOwnHandlers() async {
        let gremlin = LogGremlin(selfDraining: false)
        let handler = Recording(at: .verbose)
        await gremlin.add(handler: handler, for: .console)

        await gremlin.log("mine", at: .error, logTime: 0, "F.swift", "f()", 1)
        await gremlin.logNext()

        XCTAssertEqual(handler.lines.map(\.0), ["mine"],
                       "the instance's own handler should have received its own line")
        let remaining = await gremlin.pendingLogCount()
        XCTAssertEqual(remaining, 0, "and the line should have been taken off its own queue")
    }

    /// Draining one gremlin must not consume another's queue.
    func testDrainingOneInstanceLeavesAnotherAlone() async {
        let a = LogGremlin(selfDraining: false), b = LogGremlin(selfDraining: false)
        await a.log("for a", at: .error, logTime: 0, "F.swift", "f()", 1)
        await b.log("for b", at: .error, logTime: 0, "F.swift", "f()", 2)

        await a.logNext()

        let aLeft = await a.pendingLogCount()
        let bLeft = await b.pendingLogCount()
        XCTAssertEqual(aLeft, 0, "a drained its own line")
        XCTAssertEqual(bLeft, 1, "b's line must still be queued")
    }

    /// A handler on one instance must not see another instance's lines.
    func testHandlersAreNotSharedBetweenInstances() async {
        let a = LogGremlin(selfDraining: false), b = LogGremlin(selfDraining: false)
        let aHandler = Recording(at: .verbose), bHandler = Recording(at: .verbose)
        await a.add(handler: aHandler, for: .console)
        await b.add(handler: bHandler, for: .console)

        await a.log("only for a", at: .error, logTime: 0, "F.swift", "f()", 1)
        await a.logNext()

        XCTAssertEqual(aHandler.lines.map(\.0), ["only for a"])
        XCTAssertTrue(bHandler.lines.isEmpty, "b's handler saw a line that was not b's")
    }

    /// Draining honours the per-handler level, which is where the inverted `Log.Level` ordering
    /// is actually applied: a handler keeps lines at or below its own level.
    func testDrainingAppliesEachHandlersLevel() async {
        let gremlin = LogGremlin(selfDraining: false)
        let quiet = Recording(at: .warn)      // should keep error and warn only
        await gremlin.add(handler: quiet, for: .console)

        for level in [Log.Level.error, .warn, .info, .debug, .verbose] {
            await gremlin.log("at \(level)", at: level, logTime: 0, "F.swift", "f()", 1)
        }
        for _ in 0..<5 { await gremlin.logNext() }

        XCTAssertEqual(quiet.lines.map(\.1), [.error, .warn],
                       "a warn handler should keep only error and warn")
    }

    /// `finishLogging` drains what is queued on the instance it was called on.  While `logNext`
    /// read the global, this could not terminate for a non-global gremlin holding lines.
    func testFinishLoggingDrainsTheInstanceItWasCalledOn() async {
        let gremlin = LogGremlin(selfDraining: false)
        let handler = Recording(at: .verbose)
        await gremlin.add(handler: handler, for: .console)
        for i in 0..<5 {
            await gremlin.log("line \(i)", at: .error, logTime: 0, "F.swift", "f()", i)
        }

        await gremlin.finishLogging()

        let remaining = await gremlin.pendingLogCount()
        XCTAssertEqual(remaining, 0, "finishLogging left lines on its own queue")
        XCTAssertEqual(handler.lines.count, 5, "every queued line should have been delivered")
    }

    // MARK: - the background drain loop

    /// The one test that uses a real, self-draining gremlin — the configuration production runs.
    /// Nothing else here exercises the loop in `init`, which is what actually delivers every log
    /// line the app emits.  Polled rather than slept on, so it is not sensitive to the 1ms tick.
    func testASelfDrainingGremlinDeliversWithoutBeingPrompted() async throws {
        let gremlin = LogGremlin()          // draining, as in production
        let handler = Recording(at: .verbose)
        await gremlin.add(handler: handler, for: .console)

        for i in 0..<5 {
            await gremlin.log("line \(i)", at: .error, logTime: 0, "F.swift", "f()", i)
        }

        // give the loop up to two seconds to catch up
        for _ in 0..<200 where handler.lines.count < 5 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(handler.lines.map(\.0), (0..<5).map { "line \($0)" },
                       "the drain loop should have delivered every line, in order")
        let remaining = await gremlin.pendingLogCount()
        XCTAssertEqual(remaining, 0)
    }

    /// A gremlin built with the loop switched off must *not* deliver on its own — otherwise the
    /// tests above would be racing something after all.
    func testANonDrainingGremlinHoldsItsQueueStill() async throws {
        let gremlin = LogGremlin(selfDraining: false)
        let handler = Recording(at: .verbose)
        await gremlin.add(handler: handler, for: .console)
        await gremlin.log("held", at: .error, logTime: 0, "F.swift", "f()", 1)

        try await Task.sleep(nanoseconds: 50_000_000)   // 50x the drain loop's tick

        XCTAssertTrue(handler.lines.isEmpty, "nothing should have been delivered unprompted")
        let stillQueued = await gremlin.pendingLogCount()
        XCTAssertEqual(stillQueued, 1, "the line should still be waiting")
    }

    // MARK: - TaskWaiter

    func testFinishWaitsForEveryTaskToComplete() async {
        let waiter = TaskWaiter()
        let counter = Counter()

        for _ in 0..<10 {
            await waiter.task { await counter.bump() }
        }
        await waiter.finish()

        let value = await counter.value
        XCTAssertEqual(value, 10, "finish() returned before every task had run")
    }

    func testFinishOnAnEmptyWaiterReturnsImmediately() async {
        let waiter = TaskWaiter()
        await waiter.finish()   // must not hang
    }

    func testFinishCanBeCalledAgainAfterMoreWork() async {
        let waiter = TaskWaiter()
        let counter = Counter()

        await waiter.task { await counter.bump() }
        await waiter.finish()
        let afterFirst = await counter.value
        XCTAssertEqual(afterFirst, 1)

        await waiter.task { await counter.bump() }
        await waiter.finish()
        let afterSecond = await counter.value
        XCTAssertEqual(afterSecond, 2)
    }

    /// Tasks are awaited, not cancelled, so work already handed over still finishes — this is why
    /// the tools call `finish()` before exiting rather than just returning.
    func testWorkHandedOverBeforeFinishIsNotDropped() async {
        let waiter = TaskWaiter()
        let counter = Counter()

        await waiter.task {
            try? await Task.sleep(nanoseconds: 20_000_000)
            await counter.bump()
        }
        await waiter.finish()

        let value = await counter.value
        XCTAssertEqual(value, 1, "a slow task was dropped rather than awaited")
    }

    private actor Counter {
        var value = 0
        func bump() { value += 1 }
    }
}
