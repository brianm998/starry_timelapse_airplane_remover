import XCTest
@testable import StarCore

/// What the governor's stall watch says about a run, from the samples it is given.
///
/// The samples are made by hand: what matters is which combination of readings is worth a line
/// in the log — and, as much, which are not.  A run that is simply busy, or simply finished, or
/// waiting on a disk that is moving data, must say nothing.
final class StallWatchTests: XCTestCase {

    private func sample(window: Double = 5, cpu: Double = 0, gpu: Double = 0,
                        cpuRunning: Int = 0, throughput: Double = 0,
                        volumes: [ResourceSample.Volume] = [],
                        gpuWaiting: Int = 0, memoryWaiting: Int = 0) -> ResourceSample {
        ResourceSample(windowSeconds: window, cpuPercent: cpu, cpuRunning: cpuRunning,
                       cpuWidth: 18, cpuWaiting: 0, gpuPercent: gpu, gpuWaiting: gpuWaiting,
                       volumes: volumes, footprintBytes: 0, ledgerBytes: 0, budgetBytes: 0,
                       memoryWaiting: memoryWaiting, memoryPressure: false,
                       throughputPerMinute: throughput)
    }

    private func disk(bytesPerSecond: Double = 0, inFlight: Int = 8, waiting: Int = 41)
      -> ResourceSample.Volume {
        .init(name: "/Volumes/sp", bytesPerSecond: bytesPerSecond, inFlight: inFlight,
              width: 8, waiting: waiting)
    }

    /// The 2026-10-28 silence, as the governor saw it: the disk gate full with 41 waiting and
    /// nothing moving anywhere.  Said once it has lasted a minute, not before.
    func testAWedgedRunIsReportedAfterAMinuteAndOnlyOnce() {
        var watch = StallWatch()
        let wedged = sample(volumes: [disk()])
        for _ in 0..<11 { XCTAssertEqual(watch.observe(wedged), [], "not yet a minute") }
        XCTAssertEqual(watch.observe(wedged), [.noProgress(seconds: 60)])
        for _ in 0..<59 { XCTAssertEqual(watch.observe(wedged), [], "once, then every five minutes") }
        XCTAssertEqual(watch.observe(wedged), [.noProgress(seconds: 360)])
    }

    func testAnyActivityEndsTheCount() {
        var watch = StallWatch()
        let wedged = sample(volumes: [disk()])
        for _ in 0..<11 { _ = watch.observe(wedged) }
        // a frame finished
        XCTAssertEqual(watch.observe(sample(throughput: 3, volumes: [disk()])), [])
        for _ in 0..<11 { XCTAssertEqual(watch.observe(wedged), [], "the minute starts again") }
    }

    func testARunThatIsBusyOrIdleOrMovingDataSaysNothing() {
        var watch = StallWatch()
        // 5 minutes each of: CPU busy; a disk moving data with callers queued; nothing held at
        // all (between stages, or finished); the GPU busy.
        for readings in [sample(cpu: 90, cpuRunning: 18),
                         sample(volumes: [disk(bytesPerSecond: 200_000_000)]),
                         sample(),
                         sample(gpu: 40, gpuWaiting: 2)] {
            for _ in 0..<60 { XCTAssertEqual(watch.observe(readings), []) }
        }
    }

    /// A sample that arrives far later than it was due, over a window the CPU was idle in, is a
    /// process that did not run — and it must not also count as a wedge.
    func testALateSampleWithAnIdleCPUIsAProcessThatWasNotRunning() {
        var watch = StallWatch()
        let gap = sample(window: 147, volumes: [disk()])
        XCTAssertEqual(watch.observe(gap), [.processNotRunning(seconds: 147, cpuPercent: 0)])
        // the next ordinary sample starts the wedge count from nothing
        for _ in 0..<11 { XCTAssertEqual(watch.observe(sample(volumes: [disk()])), []) }
    }

    /// The 2026-10-30 run: half a minute of work, then 3m29s of nothing, in one sample window —
    /// which averages 2%, not 0.  It was not running for most of it all the same.
    func testALateSampleThatAveragedAFewPercentIsStillAProcessThatWasNotRunning() {
        var watch = StallWatch()
        XCTAssertEqual(watch.observe(sample(window: 209, cpu: 2, cpuRunning: 18)),
                       [.processNotRunning(seconds: 209, cpuPercent: 2)])
        XCTAssertEqual(watch.observe(sample(window: 209, cpu: 9.9, cpuRunning: 18)),
                       [.processNotRunning(seconds: 209, cpuPercent: 9.9)])
    }

    /// A governor that was merely slow to get a thread, while star used the machine, is said once
    /// as what it is.
    func testALateSampleWhileTheProcessWasBusyIsAStarvedGovernor() {
        var watch = StallWatch()
        XCTAssertEqual(watch.observe(sample(window: 40, cpu: 85, cpuRunning: 18)),
                       [.governorLate(seconds: 40, cpuPercent: 85)])
        XCTAssertEqual(watch.observe(sample(window: 40, cpu: 10, cpuRunning: 18)),
                       [.governorLate(seconds: 40, cpuPercent: 10)])
    }

    /// An ordinary sample, however busy or idle, is never a late one.
    func testAnOrdinarySampleIsNeverLate() {
        var watch = StallWatch()
        for window in [5.0, 6.0, 19.9] {
            XCTAssertEqual(watch.observe(sample(window: window, cpu: 85, cpuRunning: 18)), [])
        }
    }

    func testTheMessageNamesTheGapTheResourcesAndTheProcessState() {
        let report = ResourceReport.make(from: sample(window: 147, volumes: [disk()]))
        let line = StallWatch.message(for: .processNotRunning(seconds: 147, cpuPercent: 0),
                                      report: report)
        XCTAssertTrue(line.contains("147s"), line)
        XCTAssertTrue(line.contains("not running"), line)
        XCTAssertTrue(line.contains("every 5s"), line)
        let starved = StallWatch.message(for: .governorLate(seconds: 40, cpuPercent: 85), report: report)
        XCTAssertTrue(starved.contains("40s") && starved.contains("a thread"), starved)
        XCTAssertTrue(line.contains("resources: CPU"), line)
        XCTAssertTrue(line.contains("process state:"), line)
        // this process, asking about itself, is running
        XCTAssertTrue(["runnable", "sleeping", "running"].contains(ProcessState.describe()),
                      ProcessState.describe())
    }
}
