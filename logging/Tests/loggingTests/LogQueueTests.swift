import XCTest
@testable import logging

/// The synchronous, lock-protected log path: producers append from any thread in call order,
/// the drain is woken by an append rather than polling, and a filtered line's message is never
/// built.
final class LogQueueTests: XCTestCase {

    private final class Recording: LogHandler, @unchecked Sendable {
        let level: Log.Level
        private let lock = NSLock()
        private var _messages: [String] = []
        var messages: [String] { lock.lock(); defer { lock.unlock() }; return _messages }
        init(at level: Log.Level) { self.level = level }
        func log(message: String, at fileLocation: String, with data: LogData?,
                 at logLevel: Log.Level, logTime: TimeInterval) {
            lock.lock(); _messages.append(message); lock.unlock()
        }
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func bump() -> String { lock.lock(); n += 1; lock.unlock(); return "built" }
        var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    }

    // MARK: - laziness

    /// The process-wide minimum level is `.error` until a handler asks for more, so a verbose
    /// line is filtered, and building its message would be wasted work, or for a message that
    /// awaits, impossible to afford.
    func testAFilteredLinesMessageIsNeverBuilt() {
        let counter = Counter()
        Log.v(counter.bump())
        Log.d(counter.bump())
        Log.i(counter.bump())
        XCTAssertEqual(counter.value, 0, "a message below the minimum level was evaluated")
    }

    func testIsEnabledFollowsTheMinimumLevel() {
        XCTAssertTrue(Log.isEnabled(.error))
        XCTAssertFalse(Log.isEnabled(.verbose))
    }

    // MARK: - ordering and wake-up

    func testLinesFromOneThreadKeepTheirOrder() async {
        let gremlin = LogGremlin(selfDraining: false)
        for i in 0..<1000 {
            gremlin.enqueue("line \(i)", at: .error, logTime: 0, "F.swift", "f()", i)
        }
        var seen: [String] = []
        while let next = await gremlin.nextLog() { seen.append(next.message) }
        XCTAssertEqual(seen, (0..<1000).map { "line \($0)" })
    }

    func testConcurrentProducersLoseNothingAndKeepPerProducerOrder() async {
        let gremlin = LogGremlin(selfDraining: false)
        DispatchQueue.concurrentPerform(iterations: 8) { producer in
            for i in 0..<500 {
                gremlin.enqueue("p\(producer) \(i)", at: .error, logTime: 0, "F.swift", "f()", i)
            }
        }
        var perProducer = [Int](repeating: 0, count: 8)
        var total = 0
        while let next = await gremlin.nextLog() {
            let parts = next.message.dropFirst().split(separator: " ")
            let producer = Int(parts[0])!, index = Int(parts[1])!
            XCTAssertEqual(index, perProducer[producer], "producer \(producer) lines out of order")
            perProducer[producer] += 1
            total += 1
        }
        XCTAssertEqual(total, 4000)
    }

    /// A draining gremlin hands a line to its handler soon after it is queued, without anything
    /// polling for it, and `finishLogging` flushes whatever is left.
    func testTheDrainIsWokenByAnAppendAndFinishFlushes() async throws {
        let gremlin = LogGremlin()
        let handler = Recording(at: .error)
        await gremlin.add(handler: handler, for: .console)

        gremlin.enqueue("first", at: .error, logTime: 0, "F.swift", "f()", 1)
        let deadline = Date().addingTimeInterval(5)
        while handler.messages.isEmpty, Date() < deadline { try await Task.sleep(nanoseconds: 2_000_000) }
        XCTAssertEqual(handler.messages, ["first"], "the drain did not wake for the append")

        // idle for a while (the drain is parked), then more lines arrive
        try await Task.sleep(nanoseconds: 50_000_000)
        for i in 0..<5000 { gremlin.enqueue("bulk \(i)", at: .error, logTime: 0, "F.swift", "f()", i) }
        await gremlin.finishLogging()
        XCTAssertEqual(handler.messages.count, 5001, "finishLogging left lines unflushed")
        XCTAssertEqual(handler.messages.last, "bulk 4999")
    }

    func testWakeWithNothingQueuedReleasesAWaiter() async {
        let queue = LogQueue()
        async let waited: Void = queue.waitForWork()
        try? await Task.sleep(nanoseconds: 20_000_000)
        queue.wake()
        await waited
    }
}
