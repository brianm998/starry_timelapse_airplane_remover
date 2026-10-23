import XCTest
@testable import StarCore

/// `FrameGraphBuilder.build` suspends many times before it enqueues anything.  A cancel that
/// landed in that window found an empty queue to cancel, and the build then enqueued the
/// whole graph anyway.
final class FrameGraphBuilderCancelTests: FrameHarnessTestCase {

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func bump() { lock.lock(); n += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    }

    /// Start a build, cancel straight away, and make sure nothing is queued or completes later.
    /// The window is racy by nature, so this is repeated; the old code left operations queued
    /// whenever the cancel won the race.
    func testACancelDuringBuildLeavesNothingQueued() async throws {
        let h = try await FrameHarness.make(frameCount: 6, named: "cancelbuild")
        harness = h

        nonisolated(unsafe) let frames = h.frames

        for attempt in 0..<8 {
            let builder = FrameGraphBuilder()
            await builder.set(configManager: h.configManager)
            let completed = Counter()

            let build = Task {
                await builder.build(frames: frames,
                                    closure: { _ in completed.bump() },
                                    errorClosure: { _ in })
            }
            // wait until the build has entered, then cancel while it is still constructing.
            // (A cancel that precedes the build's entry is a different, legitimate order:
            // that build starts after the cancel and is meant to run.)
            while await builder.buildsInProgress == 0 { await Task.yield() }
            let drained = await builder.cancelAllOperationsAndWait()
            await build.value
            XCTAssertTrue(drained, "attempt \(attempt): the cancel-and-wait timed out")

            try await Task.sleep(nanoseconds: 100_000_000)
            let queued = await builder.queue.operationCount
            XCTAssertEqual(queued, 0, "attempt \(attempt): operations were enqueued after the cancel")
            XCTAssertEqual(completed.value, 0, "attempt \(attempt): a cancelled build completed")
        }
    }
}
