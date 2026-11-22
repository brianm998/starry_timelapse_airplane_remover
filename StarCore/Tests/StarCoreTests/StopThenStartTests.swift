import XCTest
@testable import StarCore

/// A Start right after a Stop must run, and a build a cancel drops must say so.
final class StopThenStartTests: FrameHarnessTestCase {

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func bump() { lock.lock(); n += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    }

    /// Cancel, then build with nothing in between: the cancel is older than the build, so the
    /// build runs to completion.  Also the gui's order: an unstructured cancel Task, awaited.
    func testStartRightAfterStopRuns() async throws {
        let h = try await FrameHarness.make(frameCount: 4, named: "stopthenstart")
        harness = h

        for viaTask in [false, true] {
            let builder = FrameGraphBuilder()
            await builder.set(configManager: h.configManager)
            if viaTask {
                let stop = Task { await builder.cancelAllOperations() }
                await stop.value
            } else {
                await builder.cancelAllOperations()
            }
            let completed = Counter()
            let cancelled = Counter()
            let frames = h.frames
            let build = Task {
                await builder.build(frames: frames,
                                    closure: { errs in
                                        // the harness's frames have no stars, so the graph ends with an alignment error: it still ran
                                        _ = errs
                                        completed.bump()
                                    },
                                    errorClosure: { _ in },
                                    cancelledClosure: { cancelled.bump() })
            }
            await build.value
            let deadline = Date().addingTimeInterval(120)
            while completed.value == 0 && cancelled.value == 0 && Date() < deadline {
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            XCTAssertEqual(completed.value, 1, "viaTask \(viaTask): the second build did not complete")
            XCTAssertEqual(cancelled.value, 0, "viaTask \(viaTask): the second build was dropped")
        }
    }

    /// A cancel that lands while a build is constructing drops it, and the caller hears of it.
    func testDroppedBuildReportsCancelled() async throws {
        let h = try await FrameHarness.make(frameCount: 6, named: "droppedbuild")
        harness = h
        let builder = FrameGraphBuilder()
        await builder.set(configManager: h.configManager)
        let completed = Counter()
        let cancelled = Counter()
        let frames = h.frames

        let build = Task {
            await builder.build(frames: frames,
                                closure: { _ in completed.bump() },
                                errorClosure: { _ in },
                                cancelledClosure: { cancelled.bump() })
        }
        while await builder.buildsInProgress == 0 { await Task.yield() }
        _ = await builder.cancelAllOperationsAndWait()
        await build.value

        XCTAssertEqual(cancelled.value, 1, "the dropped build did not report a cancel")
        XCTAssertEqual(completed.value, 0)
        let queued = await builder.queue.operationCount
        XCTAssertEqual(queued, 0)
    }
}
