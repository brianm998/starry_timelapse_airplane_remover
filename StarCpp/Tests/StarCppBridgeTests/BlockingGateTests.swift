import XCTest
@testable import StarCppBridge

final class BlockingGateTests: XCTestCase {

    private func waitUntil(_ timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.005)
        }
        return condition()
    }

    func testRaisingTheWidthWakesParkedThreads() {
        let gate = BlockingGate(max: 1)
        gate.acquire()
        let entered = NSLock()
        nonisolated(unsafe) var count = 0
        for _ in 0..<3 {
            Thread.detachNewThread {
                gate.acquire()
                entered.withLock { count += 1 }
            }
        }
        XCTAssertTrue(waitUntil { gate.waiting == 3 })
        XCTAssertEqual(entered.withLock { count }, 0)
        gate.set(max: 4)
        XCTAssertTrue(waitUntil { entered.withLock { count } == 3 })
        XCTAssertEqual(gate.inFlight, 4)
    }

    func testLoweringTheWidthLetsInFlightFinishAndAdmitsNoOneUntilItDrains() {
        let gate = BlockingGate(max: 4)
        for _ in 0..<4 { gate.acquire() }
        gate.set(max: 2)
        let entered = NSLock()
        nonisolated(unsafe) var count = 0
        Thread.detachNewThread {
            gate.acquire()
            entered.withLock { count += 1 }
        }
        XCTAssertTrue(waitUntil { gate.waiting == 1 })
        gate.release(); gate.release()          // 2 held, at the new width
        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertEqual(entered.withLock { count }, 0, "still at the new width")
        gate.release()                           // 1 held, a slot opens
        XCTAssertTrue(waitUntil { entered.withLock { count } == 1 })
    }

    func testSlotsNeverLeakAndNeverGoNegative() {
        let gate = BlockingGate(max: 2)
        gate.release()
        XCTAssertEqual(gate.inFlight, 0)
        gate.acquire(); gate.release()
        XCTAssertEqual(gate.inFlight, 0)
        gate.set(max: 0)
        XCTAssertEqual(gate.max, 1, "a zero-width gate would wedge every caller")
    }
}
