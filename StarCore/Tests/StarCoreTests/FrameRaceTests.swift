import XCTest
@testable import StarCore

/// Read-modify-write races in `FrameAirplaneRemover` that lost updates.
final class FrameRaceTests: FrameHarnessTestCase {

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func bump() { lock.lock(); n += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    }

    /// Several frames changing their clean method at once must all land.  The old code read the
    /// config, awaited, and wrote it back, so the last writer restored every other frame's
    /// previous overrides.
    func testConcurrentCleanMethodChangesAllLand() async throws {
        let h = try await FrameHarness.make(frameCount: 8, named: "overrides")
        harness = h
        nonisolated(unsafe) let frames = h.frames

        for _ in 0..<5 {
            await withTaskGroup(of: Void.self) { group in
                for frame in frames {
                    group.addTask { await frame.set(cleanMethod: .automatic(true), process: false) }
                }
            }
            let config = await h.configManager.config()
            XCTAssertEqual(config.pixelReplacementOverrides.count, frames.count)
            // flip them all back so the next round has something to change
            await withTaskGroup(of: Void.self) { group in
                for frame in frames {
                    group.addTask { await frame.set(cleanMethod: .automatic(false), process: false) }
                }
            }
            let after = await h.configManager.config()
            XCTAssertEqual(after.pixelReplacementOverrides.count, frames.count)
            XCTAssertTrue(after.pixelReplacementOverrides.values.allSatisfy { $0 == .automatic(false) })
        }
    }

    /// A timer that was replaced finishes (cancelled) after its replacement started.  It must
    /// not clear the replacement's handle, or the next restart cannot cancel it and two saves run.
    func testAFinishedTimerDoesNotForgetItsReplacement() async throws {
        let h = try await FrameHarness.make(frameCount: 1, named: "savetimer")
        harness = h
        let frame = h.frames[0]
        let b = Counter(), c = Counter()

        await frame.startSaveTimerTask(waitTime: 5) { }
        await frame.startSaveTimerTask(waitTime: 0.4) { b.bump() }   // replaces and cancels the first
        try await Task.sleep(nanoseconds: 100_000_000)               // the first unwinds here
        await frame.startSaveTimerTask(waitTime: 0.4) { c.bump() }   // must cancel the second
        try await Task.sleep(nanoseconds: 900_000_000)

        XCTAssertEqual(b.value, 0, "the replaced timer still ran its save")
        XCTAssertEqual(c.value, 1)
    }
}
