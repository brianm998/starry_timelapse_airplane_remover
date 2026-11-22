import XCTest
@testable import StarCore

final class MemoryMonitorCancellationTests: XCTestCase {

    func testCancelledWaiterIsRemoved() async throws {
        let m = MemoryMonitor()
        await m.setRealityProbe(.init(processFootprint: { 0 },
                                     systemAvailable: { 64 * 1024 * 1024 * 1024 }))
        let full = await m.snapshot().admissionBudgetBytes
        let first = await m.reserve(bytes: full)
        XCTAssertTrue(first)

        let waiter = Task { await m.reserve(bytes: 1024 * 1024) }
        var waiting = 0
        for _ in 0..<500 {
            waiting = await m.snapshot().waiting
            if waiting == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(waiting, 1)

        waiter.cancel()
        let granted = await waiter.value
        XCTAssertFalse(granted)

        let snap = await m.snapshot()
        XCTAssertEqual(snap.waiting, 0)
        XCTAssertEqual(snap.reservedBytes, full)

        await m.release(bytes: full)
        let end = await m.snapshot()
        XCTAssertEqual(end.reservedBytes, 0)
    }
}
