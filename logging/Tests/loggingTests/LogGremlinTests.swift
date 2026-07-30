import XCTest
@testable import logging

/// `LogGremlin` is the actor that queues log lines and hands them to the registered handlers one
/// at a time.  `TaskWaiter` is the other half of shutdown — every standalone tool in the repo
/// ends with `TaskWaiter.shared.finish()` followed by `gremlin.finishLogging()`.
///
/// These tests drive the queue directly rather than waiting on the gremlin's background drain
/// loop, which would be timing dependent.
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
        let gremlin = LogGremlin()
        let count = await gremlin.pendingLogCount()
        let next = await gremlin.nextLog()
        XCTAssertEqual(count, 0)
        XCTAssertNil(next)
    }

    func testALoggedLineIsQueued() async {
        let gremlin = LogGremlin()
        await gremlin.log("something happened", at: .error, logTime: 0,
                          "Caller.swift", "doThing()", 42)
        let count = await gremlin.pendingLogCount()
        XCTAssertEqual(count, 1)
    }

    /// The gremlin exists to keep the output orderly, so the queue has to be first in first out.
    func testTheQueueIsFirstInFirstOut() async {
        let gremlin = LogGremlin()
        for i in 0..<5 {
            await gremlin.log("line \(i)", at: .error, logTime: 0, "F.swift", "f()", i)
        }

        var seen: [String] = []
        while let next = await gremlin.nextLog() { seen.append(next.message) }
        XCTAssertEqual(seen, (0..<5).map { "line \($0)" })
    }

    func testDrainingTheQueueEmptiesIt() async {
        let gremlin = LogGremlin()
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
        let gremlin = LogGremlin()
        await gremlin.log("msg", at: .error, logTime: 0,
                          "/very/long/build/path/Caller.swift", "doThing()", 137)

        let queued = await gremlin.nextLog()
        let entry = try XCTUnwrap(queued)
        XCTAssertEqual(entry.fileLocation, "Caller.swift@137")
        XCTAssertFalse(entry.fileLocation.contains("/"), "the path should have been stripped")
    }

    func testAFilenameWithNoPathIsUsedAsIs() async throws {
        let gremlin = LogGremlin()
        await gremlin.log("msg", at: .warn, logTime: 0, "Bare.swift", "f()", 9)
        let queued = await gremlin.nextLog()
        let entry = try XCTUnwrap(queued)
        XCTAssertEqual(entry.fileLocation, "Bare.swift@9")
    }

    func testTheMessageLevelAndTimeAreCarriedThrough() async throws {
        let gremlin = LogGremlin()
        await gremlin.log("the message", at: .warn, logTime: 1234.5, "F.swift", "f()", 1)

        let queued = await gremlin.nextLog()
        let entry = try XCTUnwrap(queued)
        XCTAssertEqual(entry.message, "the message")
        XCTAssertEqual(entry.logLevel, .warn)
        XCTAssertEqual(entry.logTime, 1234.5)
        XCTAssertNil(entry.data, "no extra data was given")
    }

    func testExtraDataIsCarriedThrough() async throws {
        let gremlin = LogGremlin()
        await gremlin.log("with data", at: .error, logTime: 0,
                          extraData: StringLogData(with: "payload"),
                          "F.swift", "f()", 1)

        let queued = await gremlin.nextLog()
        let entry = try XCTUnwrap(queued)
        XCTAssertEqual(entry.data?.description, "payload")
    }

    // MARK: - handlers

    func testAHandlerCanBeRegisteredAndFetchedBack() async {
        let gremlin = LogGremlin()
        await gremlin.add(handler: Recording(at: .info), for: .console)

        let handlers = await gremlin.getHandlers()
        XCTAssertEqual(handlers.count, 1)
        XCTAssertNotNil(handlers[.console])
        XCTAssertEqual(handlers[.console]?.level, .info)
    }

    /// One handler per output, so registering a second console handler replaces the first rather
    /// than duplicating every line.
    func testASecondHandlerForTheSameOutputReplacesTheFirst() async {
        let gremlin = LogGremlin()
        await gremlin.add(handler: Recording(at: .info), for: .console)
        await gremlin.add(handler: Recording(at: .verbose), for: .console)

        let handlers = await gremlin.getHandlers()
        XCTAssertEqual(handlers.count, 1)
        XCTAssertEqual(handlers[.console]?.level, .verbose, "the later handler should have won")
    }

    /// The four outputs are independent — a file handler at `.debug` alongside a console handler
    /// at `.info` is the normal configuration.
    func testEachOutputHoldsItsOwnHandler() async {
        let gremlin = LogGremlin()
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
        let gremlin = LogGremlin()
        await gremlin.add(handler: Recording(at: .info), for: .console)
        await gremlin.add(handler: Recording(at: .debug), for: .file)

        await gremlin.removeHandler(for: .console)

        let handlers = await gremlin.getHandlers()
        XCTAssertEqual(handlers.count, 1)
        XCTAssertNil(handlers[.console])
        XCTAssertNotNil(handlers[.file])
    }

    func testRemovingAHandlerThatWasNeverThereIsHarmless() async {
        let gremlin = LogGremlin()
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
        let gremlin = LogGremlin()
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
        let gremlin = LogGremlin()
        await gremlin.add(handler: Recording(at: .verbose), for: .console)

        await gremlin.log("bad", at: .error, logTime: 0, "F.swift", "f()", 1)
        let count = await gremlin.pendingLogCount()
        XCTAssertEqual(count, 1)
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
