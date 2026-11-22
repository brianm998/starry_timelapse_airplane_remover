import XCTest
@testable import StarCore

/// Stop must stop: an op cancelled while parked for a slot or for memory must not go on to
/// take its reservation and run.
final class AsyncOperationCancellationTests: XCTestCase {

    private final class Flags: @unchecked Sendable {
        private let lock = NSLock()
        private var _executed = 0, _acquired = 0, _released = 0, _gateOpen = false
        func didExecute() { lock.lock(); _executed += 1; lock.unlock() }
        func didAcquire() { lock.lock(); _acquired += 1; lock.unlock() }
        func didRelease() { lock.lock(); _released += 1; lock.unlock() }
        var executed: Int { lock.lock(); defer { lock.unlock() }; return _executed }
        var acquired: Int { lock.lock(); defer { lock.unlock() }; return _acquired }
        var released: Int { lock.lock(); defer { lock.unlock() }; return _released }
        var gateOpen: Bool {
            get { lock.lock(); defer { lock.unlock() }; return _gateOpen }
            set { lock.lock(); _gateOpen = newValue; lock.unlock() }
        }
    }

    private final class RecordingOp: AsyncOperation, @unchecked Sendable {
        let flags: Flags
        let gateSlot: Bool
        init(flags: Flags, bytes: UInt64, gateSlot: Bool = false) {
            self.flags = flags
            self.gateSlot = gateSlot
            super.init(for: .merge, rawImageBytes: bytes, memoryMultiplier: 1)
        }
        override func acquireExecutionSlot() async {
            flags.didAcquire()
            if gateSlot {
                // Parked for a slot until the test opens the gate.
                while !flags.gateOpen { try? await Task.sleep(for: .milliseconds(10)) }
            }
        }
        override func releaseExecutionSlot() async { flags.didRelease() }
        override func asyncExecute() async { flags.didExecute() }
    }

    func testCancelledWhileWaitingForMemoryDoesNotExecute() async throws {
        let monitor = MemoryMonitor.shared
        let before = await monitor.snapshot()
        // Bigger than any budget, so it is admitted at once and leaves the ledger over
        // budget however the effective budget moves with the machine's state.
        let hog = UInt64(ProcessInfo.processInfo.physicalMemory)
        await monitor.reserve(bytes: hog)

        let flags = Flags()
        let op = RecordingOp(flags: flags, bytes: 1024 * 1024)
        op.start()

        var waiting = 0
        for _ in 0..<500 {
            waiting = await monitor.snapshot().waiting
            if waiting > before.waiting { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertGreaterThan(waiting, before.waiting, "op never parked on the memory gate")

        op.cancel()
        await op.task?.value
        XCTAssertTrue(op.isFinished)
        XCTAssertEqual(flags.executed, 0)
        XCTAssertEqual(flags.acquired, flags.released)

        let during = await monitor.snapshot()
        XCTAssertEqual(during.waiting, before.waiting)
        XCTAssertEqual(during.reservedBytes, before.reservedBytes + hog)

        await monitor.release(bytes: hog)
        // Releasing must not hand the cancelled op a reservation.
        try await Task.sleep(for: .milliseconds(200))
        let after = await monitor.snapshot()
        XCTAssertEqual(after.reservedBytes, before.reservedBytes)
        XCTAssertEqual(flags.executed, 0)
    }

    func testCancelledWhileWaitingForSlotDoesNotExecute() async throws {
        let monitor = MemoryMonitor.shared
        let before = await monitor.snapshot()

        let flags = Flags()
        let op = RecordingOp(flags: flags, bytes: 1024 * 1024, gateSlot: true)
        op.start()
        for _ in 0..<500 where flags.acquired == 0 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(flags.acquired, 1)

        op.cancel()
        flags.gateOpen = true
        await op.task?.value

        XCTAssertTrue(op.isFinished)
        XCTAssertEqual(flags.executed, 0)
        XCTAssertEqual(flags.released, flags.acquired, "slot must be released exactly once")
        let after = await monitor.snapshot()
        XCTAssertEqual(after.reservedBytes, before.reservedBytes, "nothing may be reserved")
    }
}
