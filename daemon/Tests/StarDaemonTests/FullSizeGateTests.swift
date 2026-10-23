import XCTest
@testable import stard

/// `FullSizeGate` lets one whole-frame copy be made at a time.
final class FullSizeGateTests: XCTestCase {

    private actor Probe {
        private(set) var running = 0
        private(set) var peak = 0
        private(set) var order: [Int] = []
        func enter(_ id: Int) { running += 1; peak = max(peak, running); order.append(id) }
        func leave() { running -= 1 }
    }

    private func waitFor(_ condition: @escaping () async -> Bool) async {
        for _ in 0..<600 {
            if await condition() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    func testAtMostOneRunsAtATimeAndTheyRunInArrivalOrder() async {
        let gate = FullSizeGate()
        let probe = Probe()
        var handles: [Task<Void, Never>] = []
        for i in 0..<8 {
            handles.append(Task {
                _ = await gate.run {
                    await probe.enter(i)
                    try? await Task.sleep(nanoseconds: 60_000_000)
                    await probe.leave()
                }
            })
            // arrive one at a time so the order is defined: the job is long enough that
            // everything launched so far is still running or queued
            await waitFor { await probe.running + gate.waitingCount >= i + 1 }
        }
        for h in handles { await h.value }
        let peak = await probe.peak
        XCTAssertEqual(peak, 1, "two full-size jobs ran at once")
        let order = await probe.order
        XCTAssertEqual(order, Array(0..<8))
        let busy = await gate.isBusy
        XCTAssertFalse(busy)
    }

    /// A caller arriving at the instant the slot changes hands must not run beside the waiter it was
    /// handed to.
    func testAnArrivalDuringAHandOverDoesNotRunAlongsideTheWaiter() async {
        for _ in 0..<10 {
            let gate = FullSizeGate()
            let probe = Probe()
            let first = Task { _ = await gate.run { try? await Task.sleep(nanoseconds: 120_000_000) } }
            await waitFor { await gate.isBusy }
            let waiter = Task { _ = await gate.run { await probe.enter(1); try? await Task.sleep(nanoseconds: 30_000_000); await probe.leave() } }
            await waitFor { await gate.waitingCount == 1 }
            let latecomer = Task { _ = await gate.run { await probe.enter(2); try? await Task.sleep(nanoseconds: 30_000_000); await probe.leave() } }
            await first.value; await waiter.value; await latecomer.value
            let peak = await probe.peak
            XCTAssertEqual(peak, 1)
        }
    }

    func testACancelledWaiterNeverRuns() async {
        let gate = FullSizeGate()
        let probe = Probe()
        let holder = Task { _ = await gate.run { try? await Task.sleep(nanoseconds: 80_000_000) } }
        await waitFor { await gate.isBusy }
        let waiter = Task { await gate.run { await probe.enter(9); return true } }
        await waitFor { await gate.waitingCount == 1 }
        waiter.cancel()
        let result = await waiter.value
        XCTAssertNil(result, "a cancelled waiter should get nil, not a result")
        await holder.value
        let order = await probe.order
        XCTAssertTrue(order.isEmpty, "a cancelled waiter ran its work")
        let waiting = await gate.waitingCount
        XCTAssertEqual(waiting, 0)
        let busy = await gate.isBusy
        XCTAssertFalse(busy)
    }

    func testACallerCancelledBeforeItStartsDoesNotRun() async {
        let gate = FullSizeGate()
        let probe = Probe()
        let task = Task {
            try? await Task.sleep(nanoseconds: 50_000_000)   // cancelled while sleeping
            return await gate.run { await probe.enter(1); return true }
        }
        task.cancel()
        let result = await task.value
        XCTAssertNil(result)
        let order = await probe.order
        XCTAssertTrue(order.isEmpty)
    }
}
