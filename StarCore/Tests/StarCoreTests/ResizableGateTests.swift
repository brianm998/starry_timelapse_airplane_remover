import XCTest
@testable import StarCore

final class ResizableGateTests: XCTestCase {

    private func waitUntil(_ timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    func testRaisingTheWidthWakesWaiters() async {
        let gate = ResizableGate(max: 1)
        await gate.acquire()
        let tasks = (0..<3).map { _ in Task { await gate.acquire() } }
        let parked = await waitUntil { gate.waiting == 3 }
        XCTAssertTrue(parked)
        gate.set(max: 4)
        for task in tasks { await task.value }
        XCTAssertEqual(gate.inFlight, 4)
        XCTAssertEqual(gate.waiting, 0)
    }

    func testLoweringTheWidthLetsInFlightFinishAndAdmitsNoOneUntilItDrains() async {
        let gate = ResizableGate(max: 4)
        for _ in 0..<4 { await gate.acquire() }
        gate.set(max: 2)
        let admitted = Admitted()
        let waiter = Task { await gate.acquire(); admitted.set() }
        let parked = await waitUntil { gate.waiting == 1 }
        XCTAssertTrue(parked)
        gate.release(); gate.release()
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(admitted.value, "still at the new width")
        gate.release()
        await waiter.value
        XCTAssertTrue(admitted.value)
    }

    func testSlotsNeverLeakOnCancellation() async {
        let gate = ResizableGate(max: 1)
        await gate.acquire()
        let waiter = Task {
            await gate.acquire()
            // a cancelled waiter is granted a slot so the release below stays balanced
            gate.release()
        }
        let parked = await waitUntil { gate.waiting == 1 }
        XCTAssertTrue(parked)
        waiter.cancel()
        await waiter.value
        gate.release()
        XCTAssertEqual(gate.inFlight, 0)
        XCTAssertEqual(gate.waiting, 0)
    }

    func testExtraReleaseDoesNotInflateTheWidth() async {
        let gate = ResizableGate(max: 1)
        gate.release()
        await gate.acquire()
        XCTAssertEqual(gate.inFlight, 1)
        let waiter = Task { await gate.acquire() }
        let parked = await waitUntil { gate.waiting == 1 }
        XCTAssertTrue(parked, "one slot, one holder: the second caller must wait")
        gate.release()
        await waiter.value
        gate.release()
    }

    /// A native thread that queued before some tasks gets its slot before them. The old gate
    /// served every parked task first, so a stream of tasks could starve a blocking caller.
    func testABlockingCallerQueuedFirstIsGrantedBeforeLaterTasks() async {
        let gate = ResizableGate(max: 1)
        await gate.acquire()
        let order = Order()

        let blocker = Thread { gate.acquireBlocking(); order.add("thread"); gate.release() }
        blocker.start()
        let parkedThread = await waitUntil { gate.waiting == 1 }
        XCTAssertTrue(parkedThread)

        // one at a time: tasks started together can park in either order
        var tasks: [Task<Void, Never>] = []
        for i in 0..<3 {
            tasks.append(Task { await gate.acquire(); order.add("task\(i)"); gate.release() })
            let parked = await waitUntil { gate.waiting == 2 + i }
            XCTAssertTrue(parked)
        }

        gate.release()
        for task in tasks { await task.value }
        let done = await waitUntil { order.values.count == 4 }
        XCTAssertTrue(done)
        XCTAssertEqual(order.values, ["thread", "task0", "task1", "task2"])
    }

    /// And the other way round: tasks that queued first are not overtaken by a later thread.
    func testATaskQueuedFirstIsNotOvertakenByALaterBlockingCaller() async {
        let gate = ResizableGate(max: 1)
        await gate.acquire()
        let order = Order()

        let task = Task { await gate.acquire(); order.add("task"); gate.release() }
        let parkedTask = await waitUntil { gate.waiting == 1 }
        XCTAssertTrue(parkedTask)
        let blocker = Thread { gate.acquireBlocking(); order.add("thread"); gate.release() }
        blocker.start()
        let parkedBoth = await waitUntil { gate.waiting == 2 }
        XCTAssertTrue(parkedBoth)

        gate.release()
        await task.value
        let done = await waitUntil { order.values.count == 2 }
        XCTAssertTrue(done)
        XCTAssertEqual(order.values, ["task", "thread"])
    }

    /// Many native threads and tasks hammering a narrow gate: nothing is lost, nothing is
    /// double-granted, and every one of them gets through.
    func testNoLostWakeupsUnderStress() async {
        let gate = ResizableGate(max: 3)
        let inside = Gauge()
        let finished = Order()
        let threads = 24, tasks = 24, rounds = 40

        let group = DispatchGroup()
        for t in 0..<threads {
            group.enter()
            Thread {
                for _ in 0..<rounds {
                    gate.acquireBlocking()
                    inside.enter()
                    Thread.sleep(forTimeInterval: 0.0002)
                    inside.leave()
                    gate.release()
                }
                finished.add("thread\(t)")
                group.leave()
            }.start()
        }
        await withTaskGroup(of: Void.self) { g in
            for t in 0..<tasks {
                g.addTask {
                    for _ in 0..<rounds {
                        await gate.acquire()
                        inside.enter()
                        try? await Task.sleep(nanoseconds: 200_000)
                        inside.leave()
                        gate.release()
                    }
                    finished.add("task\(t)")
                }
            }
        }
        let threadsDone = await waitUntil(30) { finished.values.count == threads + tasks }
        XCTAssertTrue(threadsDone, "some callers never got through the gate")
        XCTAssertLessThanOrEqual(inside.peak, 3, "more callers were inside than the width allows")
        XCTAssertEqual(gate.inFlight, 0)
        XCTAssertEqual(gate.waiting, 0)
    }

    private final class Order: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []
        func add(_ s: String) { lock.lock(); items.append(s); lock.unlock() }
        var values: [String] { lock.lock(); defer { lock.unlock() }; return items }
    }

    private final class Gauge: @unchecked Sendable {
        private let lock = NSLock()
        private var current = 0
        private(set) var peak = 0
        func enter() { lock.lock(); current += 1; peak = max(peak, current); lock.unlock() }
        func leave() { lock.lock(); current -= 1; lock.unlock() }
    }

    func testBlockingAndAsyncCallersShareOneCount() async {
        let gate = ResizableGate(max: 1)
        gate.acquireBlocking()
        let waiter = Task { await gate.acquire() }
        let parked = await waitUntil { gate.waiting == 1 }
        XCTAssertTrue(parked)
        gate.release()
        await waiter.value
        XCTAssertEqual(gate.inFlight, 1)
        gate.release()
    }

    final class Admitted: @unchecked Sendable {
        private let lock = NSLock()
        private var flag = false
        var value: Bool { lock.withLock { flag } }
        func set() { lock.withLock { flag = true } }
    }
}

final class ResourceProfileTests: XCTestCase {

    func testFullIsTheDefaultAndEveryOldConfigStartsThere() throws {
        XCTAssertEqual(Config().resourceProfile, .full)
        let old = try JSONDecoder().decode(
          Config.self, from: Data(#"{"numberOfFramesToProcessConcurrently": 6}"#.utf8))
        XCTAssertEqual(old.resourceProfile, .full)
        XCTAssertEqual(old.numberOfFramesToProcessConcurrently, 6,
                       "the old key still loads, and waits in Custom's depth cap")
    }

    func testPresetsScaleWithTheMachine() {
        let full = ResourceLimits.preset(.full, cores: 18)
        XCTAssertEqual(full.cpuWidth, 18)
        XCTAssertEqual(full.pipelineDepth, 72)
        XCTAssertEqual(full.gpuWidth, 8)
        XCTAssertEqual(full.diskStreamsPerVolume, 4)
        XCTAssertEqual(full.memoryFraction, 0.85)

        let balanced = ResourceLimits.preset(.balanced, cores: 18)
        XCTAssertEqual(balanced.cpuWidth, 9)
        XCTAssertEqual(balanced.qos, .utility)
        XCTAssertEqual(balanced.pipelineDepth, 36)

        let light = ResourceLimits.preset(.light, cores: 18)
        XCTAssertEqual(light.cpuWidth, 4)
        XCTAssertEqual(light.qos, .background)
        XCTAssertEqual(light.gpuDutyCycle, 0.5)
        XCTAssertEqual(light.diskStreamsPerVolume, 1)
        XCTAssertEqual(light.ioPolicy, .throttle)
        XCTAssertEqual(ResourceLimits.preset(.light, cores: 4).cpuWidth, 2, "never below 2")
    }

    func testCustomReadsTheLegacyFieldsForDepthAndMemory() {
        var c = Config()
        c.resourceProfile = .custom
        c.numberOfFramesToProcessConcurrently = 5
        c.maxMatMemoryFraction = 0.5
        c.customResources.cpuWidth = 3
        XCTAssertEqual(c.resources.pipelineDepth, 5)
        XCTAssertEqual(c.resources.memoryFraction, 0.5)
        XCTAssertEqual(c.resources.cpuWidth, 3)
        XCTAssertEqual(c.frameConcurrency, 5)
    }

    func testProfileRoundTrips() throws {
        var c = Config()
        c.resourceProfile = .light
        c.customResources.gpuWidth = 3
        let back = try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(c))
        XCTAssertEqual(back.resourceProfile, .light)
        XCTAssertEqual(back.customResources.gpuWidth, 3)
    }

    func testPipelineDepthIsWiderThanFrameConcurrency() {
        let c = Config()
        XCTAssertGreaterThan(c.pipelineDepth, c.frameConcurrency,
                             "keypoint limits must stay at or under the queue width")
    }
}
