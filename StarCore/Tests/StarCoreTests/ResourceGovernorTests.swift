import XCTest
@testable import StarCore

final class ResourceGovernorTests: XCTestCase {

    /// The merge phase of the reference sequence: ~212MB/s to a USB SSD whose gate is full
    /// with 9 callers waiting, a nearly idle CPU and GPU, and a ledger full of ops that are
    /// holding their memory while they wait for that disk.
    private func referenceMergePhase() -> ResourceSample {
        ResourceSample(
          windowSeconds: 5,
          cpuPercent: 14, cpuRunning: 3, cpuWidth: 18, cpuWaiting: 0,
          gpuPercent: 4, gpuWaiting: 0,
          volumes: [.init(name: "/Volumes/rp", bytesPerSecond: 212_000_000,
                          inFlight: 4, width: 4, waiting: 9)],
          footprintBytes: 9_200_000_000, ledgerBytes: 23_700_000_000,
          budgetBytes: 33_600_000_000, memoryWaiting: 6, memoryPressure: false,
          throughputPerMinute: 170)
    }

    func testTheBottleneckLineNamesTheDiskInTheMergePhase() {
        let report = ResourceReport.make(from: referenceMergePhase())
        XCTAssertEqual(report.limitedBy, .disk("/Volumes/rp"),
                       "a full ledger beside a saturated disk is the disk's doing")
        XCTAssertTrue(report.line.hasSuffix("limited by disk /Volumes/rp"), report.line)
        XCTAssertTrue(report.line.contains("/Volumes/rp 212MB/s (gate 4/4, 9 waiting)"), report.line)
        XCTAssertEqual(report.limitedByText, "limited by disk /Volumes/rp")
    }

    func testMemoryIsBlamedWhenNothingElseIsSaturated() {
        var s = referenceMergePhase()
        s.volumes[0].waiting = 0
        s.volumes[0].inFlight = 1
        XCTAssertEqual(ResourceReport.make(from: s).limitedBy, .memory)
    }

    func testCPUAndGPUAreNamedWhenTheirGatesQueue() {
        var s = referenceMergePhase()
        s.volumes = []
        s.memoryWaiting = 0
        s.cpuWaiting = 5; s.cpuRunning = 18
        XCTAssertEqual(ResourceReport.make(from: s).limitedBy, .cpu)
        s.gpuWaiting = 2
        s.gpuPercent = 60   // callers queued and the device genuinely busy
        XCTAssertEqual(ResourceReport.make(from: s).limitedBy, .gpu, "GPU outranks CPU")
    }

    /// Callers queued for a slot while the device is nearly idle are waiting on something that
    /// is not the GPU (staging copies hold slots), so the GPU is not blamed.
    func testAQueueForAnIdleGPUIsNotBlamedOnTheGPU() {
        var s = referenceMergePhase()
        s.volumes = []
        s.memoryWaiting = 0
        s.cpuWaiting = 0
        s.gpuWaiting = 9
        s.gpuPercent = 3
        s.gpuSlotPercent = 90
        XCTAssertNotEqual(ResourceReport.make(from: s).limitedBy, .gpu)
    }

    func testADeviceBusyOverEightyFivePercentIsTheGPUsDoingWithNoQueue() {
        var s = referenceMergePhase()
        s.volumes = []
        s.memoryWaiting = 0
        s.gpuPercent = 92
        XCTAssertEqual(ResourceReport.make(from: s).limitedBy, .gpu)
    }

    func testTheStatusLineShowsBothGPUNumbers() {
        var s = referenceMergePhase()
        s.gpuPercent = 12; s.gpuSlotPercent = 70
        XCTAssertTrue(ResourceReport.make(from: s).line.contains("GPU 12% (slots 70%)"))
    }

    func testNothingIsBlamedWhenNothingIsSaturated() {
        var s = referenceMergePhase()
        s.volumes = []
        s.memoryWaiting = 0
        XCTAssertNil(ResourceReport.make(from: s).limitedBy)
    }

    // MARK: - Auto-tune

    func testAutoTuneRaisesWhileThroughputRisesAndNeverPassesTheCap() {
        var t = AutoTuner()
        var throughput = 100.0
        for _ in 0..<20 {
            t.step(throughput: throughput, diskSaturated: true, memoryPressure: false)
            throughput *= 1.2
        }
        XCTAssertEqual(t.extraStreams, AutoTuner.maxExtraStreams)
    }

    func testAutoTuneTakesBackAStreamThatDidNotHelpAndWaits() {
        var t = AutoTuner()
        t.step(throughput: 100, diskSaturated: true, memoryPressure: false)
        XCTAssertEqual(t.extraStreams, 1)
        t.step(throughput: 101, diskSaturated: true, memoryPressure: false)   // +1%: not enough
        XCTAssertEqual(t.extraStreams, 0, "back to Full's own width")
        for _ in 0..<AutoTuner.plateauWindows {
            t.step(throughput: 100, diskSaturated: true, memoryPressure: false)
            XCTAssertEqual(t.extraStreams, 0, "no re-raise during the plateau")
        }
        t.step(throughput: 100, diskSaturated: true, memoryPressure: false)
        XCTAssertEqual(t.extraStreams, 1, "tries again once the plateau is over")
    }

    func testAutoTuneBacksOffOnMemoryPressureAndNeverGoesBelowFull() {
        var t = AutoTuner()
        var throughput = 100.0
        for _ in 0..<4 {
            t.step(throughput: throughput, diskSaturated: true, memoryPressure: false)
            throughput *= 1.5
        }
        XCTAssertGreaterThan(t.extraStreams, 1)
        let before = t.extraStreams
        t.step(throughput: throughput, diskSaturated: true, memoryPressure: true)
        XCTAssertEqual(t.extraStreams, before - 1)
        for _ in 0..<20 { t.step(throughput: 1, diskSaturated: false, memoryPressure: true) }
        XCTAssertEqual(t.extraStreams, 0)
    }

    func testAutoTuneLeavesAnUnsaturatedDiskAlone() {
        var t = AutoTuner()
        for _ in 0..<10 { t.step(throughput: 100, diskSaturated: false, memoryPressure: false) }
        XCTAssertEqual(t.extraStreams, 0)
    }

    // MARK: - volumes that share a name

    /// Two gates reporting one mount name used to trap the governor's tick
    /// (`Dictionary(uniqueKeysWithValues:)` on the names).  They are separate volumes and keep
    /// separate counters.
    func testTwoVolumesWithOneNameDoNotTrapAndKeepTheirOwnBytes() {
        let a = IOWork.VolumeStatus(volume: "dev1", name: "/", bytes: 100, inFlight: 0, waiting: 0, width: 2)
        let b = IOWork.VolumeStatus(volume: "dev2", name: "/", bytes: 40, inFlight: 0, waiting: 0, width: 2)
        let bytes = ResourceGovernor.bytesByVolume([a, b])
        XCTAssertEqual(bytes["dev1"], 100)
        XCTAssertEqual(bytes["dev2"], 40)
    }

    /// A symlinked directory and its target are the same volume.
    func testASymlinkedPathResolvesToTheSameVolumeAsItsTarget() throws {
        let base = NSTemporaryDirectory() + "iowork-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: base + "/real", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: base + "/link", withDestinationPath: base + "/real")
        defer { try? FileManager.default.removeItem(atPath: base) }
        XCTAssertEqual(IOWork.volume(of: base + "/link/file.tif"), IOWork.volume(of: base + "/real/file.tif"))
    }
}
