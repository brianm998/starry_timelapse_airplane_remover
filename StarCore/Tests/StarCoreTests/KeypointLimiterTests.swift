import XCTest
@testable import StarCore

/// Regression tests for the keypoint concurrency gate.
///
/// The bug these exist for: the limiter used to be enforced from `KeypointOp.isReady`,
/// and `--num-concurrent-renders 1` ran exactly one keypoint op and then went idle
/// forever.  `testBarrierReleaseDoesNotDeadlock` is the direct reproduction — it fails
/// against the old readiness-gated implementation and passes against the current one.
final class KeypointLimiterTests: XCTestCase {

    /// Stand-in for `KeypointOp`: same shape (async op on an `OperationQueue`, gated by
    /// the limiter via `acquireExecutionSlot`), without needing an image sequence.
    private final class GatedOp: AsyncOperation, @unchecked Sendable {
        private let limiter: KeypointLimiter
        private let tally: Tally
        private let work: TimeInterval

        init(limiter: KeypointLimiter, work: TimeInterval, tally: Tally) {
            self.limiter = limiter
            self.tally = tally
            self.work = work
            super.init(for: .starKeypoints)
        }

        override func acquireExecutionSlot() async { await limiter.acquire() }
        override func releaseExecutionSlot() async { limiter.release() }

        override func asyncExecute() async {
            // Bracket the work itself, not the operation lifetime: the concurrency the
            // limiter promises is over slot holders, and the slot is released the
            // instant this returns.  Measuring any wider (a completionBlock, say) would
            // count an op that has already handed its slot on, and flake.
            tally.enter()
            try? await Task.sleep(for: .seconds(work))
            tally.exit()
        }
    }

    /// Counts executions and the peak number running at once.
    private final class Tally: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var runs = 0
        private(set) var peakConcurrent = 0
        private var live = 0

        func enter() {
            lock.lock()
            runs += 1
            live += 1
            peakConcurrent = Swift.max(peakConcurrent, live)
            lock.unlock()
        }

        func exit() { lock.lock(); live -= 1; lock.unlock() }
    }

    private func waitForFinish(_ ops: [Operation], timeout: TimeInterval) -> Int {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if ops.allSatisfy({ $0.isFinished }) { break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return ops.filter { $0.isFinished }.count
    }

    /// Every gated op shares one upstream dependency, so they all become ready at the
    /// same instant — exactly how keypoint ops hang off the merged-horizon op.  That
    /// simultaneity is what the readiness-gated limiter could not survive.
    ///
    /// Run at queue concurrency 1 / limit 1, which is the `--num-concurrent-renders 1`
    /// case from `MemoryProbe`'s documented measurement recipe.
    func testBarrierReleaseDoesNotDeadlock() throws {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1

        let limiter = KeypointLimiter(max: 1)
        let tally = Tally()

        let barrier = BlockOperation {}

        let ops = (0..<6).map { _ -> GatedOp in
            let op = GatedOp(limiter: limiter, work: 0.02, tally: tally)
            op.queuePriority = .high
            op.addDependency(barrier)
            return op
        }

        queue.addOperation(barrier)
        for op in ops { queue.addOperation(op) }

        let finished = waitForFinish(ops, timeout: 20)

        XCTAssertEqual(finished, ops.count,
                       "gated ops stalled: only \(finished) of \(ops.count) finished")
        XCTAssertEqual(tally.runs, ops.count, "each op should run exactly once")
        XCTAssertEqual(limiter.inFlight, 0, "every acquired slot should have been released")
        XCTAssertEqual(limiter.waiting, 0, "no waiter should be left parked")
    }

    /// The limiter must still actually limit — a gate that never blocks would also pass
    /// the deadlock test above.
    func testLimitIsEnforced() throws {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 8

        let limiter = KeypointLimiter(max: 2)
        let tally = Tally()

        let barrier = BlockOperation {}
        let ops = (0..<8).map { _ -> GatedOp in
            let op = GatedOp(limiter: limiter, work: 0.05, tally: tally)
            op.addDependency(barrier)
            return op
        }

        queue.addOperation(barrier)
        for op in ops { queue.addOperation(op) }

        let finished = waitForFinish(ops, timeout: 20)

        XCTAssertEqual(finished, ops.count)
        XCTAssertEqual(tally.runs, ops.count)
        XCTAssertLessThanOrEqual(tally.peakConcurrent, 2,
                                 "limiter let \(tally.peakConcurrent) ops run against a max of 2")
        XCTAssertEqual(limiter.inFlight, 0)
    }

    /// Raising the limit at runtime — the GUI's concurrency slider — has to wake ops
    /// already parked.  Nothing else will.
    func testRaisingMaxWakesParkedWaiters() async throws {
        let limiter = KeypointLimiter(max: 1)

        await limiter.acquire()          // occupy the only slot
        XCTAssertEqual(limiter.inFlight, 1)

        let parked = Task { await limiter.acquire() }

        // Let it actually park before touching the limit, so this exercises the wake
        // path rather than the fits-immediately path.
        var spins = 0
        while limiter.waiting == 0, spins < 500 {
            try await Task.sleep(for: .milliseconds(10))
            spins += 1
        }
        XCTAssertEqual(limiter.waiting, 1, "second acquire should have parked")

        limiter.set(max: 2)
        await parked.value

        XCTAssertEqual(limiter.inFlight, 2)
        XCTAssertEqual(limiter.waiting, 0)

        limiter.release()
        limiter.release()
        XCTAssertEqual(limiter.inFlight, 0)
    }

    /// A cancelled waiter must not hang, and must still be balanced — `acquire()`
    /// promises exactly one `release()` per call, cancelled or not.
    func testCancelledWaiterUnblocksAndStaysBalanced() async throws {
        let limiter = KeypointLimiter(max: 1)

        await limiter.acquire()

        let parked = Task { await limiter.acquire() }

        var spins = 0
        while limiter.waiting == 0, spins < 500 {
            try await Task.sleep(for: .milliseconds(10))
            spins += 1
        }
        XCTAssertEqual(limiter.waiting, 1)

        parked.cancel()
        await parked.value   // must return rather than hang

        XCTAssertEqual(limiter.waiting, 0)
        limiter.release()
        limiter.release()
        XCTAssertEqual(limiter.inFlight, 0)
    }
}
