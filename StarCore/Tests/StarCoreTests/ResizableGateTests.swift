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
