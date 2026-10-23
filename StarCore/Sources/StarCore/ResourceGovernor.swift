import Foundation
import logging
import StarCoreC
import StarCppBridge
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Completed work, weighted by how much each kind of op costs, so a rate in "weighted ops
/// per minute" means about the same thing in phase A (keypoints) and phase B (merges).
public enum OperationThroughput {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var total = 0.0

    static func weight(of type: OperationType) -> Double {
        switch type {
        case .merge, .outliers: 10
        case .starKeypoints, .earthKeypoints: 5
        case .horizon, .mergedHorizon: 3
        default: 1
        }
    }

    static func record(_ type: OperationType) {
        lock.withLock { total += weight(of: type) }
    }

    public static var weightedTotal: Double { lock.withLock { total } }
}

/// One reading of every resource, over a window.
public struct ResourceSample: Sendable, Equatable {
    public struct Volume: Sendable, Equatable {
        public var name: String
        public var bytesPerSecond: Double
        public var inFlight: Int
        public var width: Int
        public var waiting: Int
    }

    public var windowSeconds: Double
    /// Percent of the whole machine (all cores = 100), from star's own CPU time.
    public var cpuPercent: Double
    public var cpuRunning: Int
    public var cpuWidth: Int
    public var cpuWaiting: Int
    /// Percent of the window star held a GPU slot.
    public var gpuPercent: Double
    public var gpuWaiting: Int
    public var volumes: [Volume]
    public var footprintBytes: UInt64
    public var ledgerBytes: UInt64
    public var budgetBytes: UInt64
    public var memoryWaiting: Int
    public var memoryPressure: Bool
    /// Weighted operations completed per minute over the window.
    public var throughputPerMinute: Double
}

public enum LimitingResource: Sendable, Equatable {
    case disk(String)
    case gpu
    case cpu
    case memory

    public var description: String {
        switch self {
        case .disk(let volume): "disk \(volume)"
        case .gpu: "GPU"
        case .cpu: "CPU"
        case .memory: "memory"
        }
    }
}

/// The status line, and the resource it blames.
public struct ResourceReport: Sendable, Equatable {
    public var line: String
    public var limitedBy: LimitingResource?
    public var sample: ResourceSample

    /// Just the last clause, for the GUI.
    public var limitedByText: String {
        limitedBy.map { "limited by \($0.description)" } ?? "not limited by a resource"
    }

    /// Which resource is holding the run back, if one is.
    ///
    /// A resource is *saturated* when its gate is full and callers are queued behind it
    /// (the GPU gate by queue alone, since the GPU's own busy time is only wall time inside
    /// its slots). When several are, the order is disk, GPU, CPU, memory: work that is
    /// waiting on a slow disk is *holding* its memory reservation while it waits, so a full
    /// ledger beside a saturated disk is the disk's doing.
    static func limiter(in sample: ResourceSample) -> LimitingResource? {
        if let volume = sample.volumes
            .filter({ $0.waiting > 0 && $0.inFlight >= $0.width })
            .max(by: { Double($0.waiting) / Double(max($0.width, 1))
                       < Double($1.waiting) / Double(max($1.width, 1)) })
        {
            return .disk(volume.name)
        }
        if sample.gpuWaiting > 0 || sample.gpuPercent >= 85 { return .gpu }
        if (sample.cpuWaiting > 0 && sample.cpuRunning >= sample.cpuWidth) || sample.cpuPercent >= 85 {
            return .cpu
        }
        if sample.memoryWaiting > 0 || sample.memoryPressure { return .memory }
        return nil
    }

    static func make(from sample: ResourceSample) -> ResourceReport {
        func gb(_ bytes: UInt64) -> String { String(format: "%.1f", Double(bytes) / 1_073_741_824) }
        var parts: [String] = []
        parts.append("CPU \(Int(sample.cpuPercent.rounded()))% (gate \(sample.cpuRunning)/\(sample.cpuWidth))")
        parts.append("GPU \(Int(sample.gpuPercent.rounded()))%")
        for v in sample.volumes {
            var part = "\(v.name) \(Int((v.bytesPerSecond / 1_000_000).rounded()))MB/s "
            part += "(gate \(v.inFlight)/\(v.width)"
            if v.waiting > 0 { part += ", \(v.waiting) waiting" }
            part += ")"
            parts.append(part)
        }
        parts.append("memory \(gb(sample.footprintBytes))/\(gb(sample.budgetBytes))GB "
                     + "(ledger \(gb(sample.ledgerBytes))GB)")
        let limiter = limiter(in: sample)
        var line = "resources: " + parts.joined(separator: ", ")
        line += " — " + (limiter.map { "limited by \($0.description)" } ?? "not limited by a resource")
        return ResourceReport(line: line, limitedBy: limiter, sample: sample)
    }
}

/// Hill-climbs the per-volume disk stream count in Full, from Full's own width upward.
///
/// Never worse than fixed Full: it only ever adds streams above Full's, and takes them
/// back when an added stream did not buy throughput or memory is under pressure, so the
/// floor is Full itself. (Pipeline depth is not tuned: Full's is already 4x the cores.)
public struct AutoTuner: Sendable, Equatable {
    public static let maxExtraStreams = 4
    /// A raise has to buy at least this much throughput to be kept.
    static let requiredGain = 1.03
    /// Windows to leave alone after a raise that did not help.
    static let plateauWindows = 6

    public private(set) var extraStreams = 0
    private var throughputBeforeRaise: Double?
    private var plateauRemaining = 0

    public init() {}

    /// Feed one window. Returns the extra streams to run with from now on.
    @discardableResult
    public mutating func step(throughput: Double, diskSaturated: Bool, memoryPressure: Bool) -> Int {
        if memoryPressure {
            // Streams hold reservations while they wait; shed what was added.
            extraStreams = max(0, extraStreams - 1)
            throughputBeforeRaise = nil
            plateauRemaining = Self.plateauWindows
            return extraStreams
        }
        if let before = throughputBeforeRaise {
            throughputBeforeRaise = nil
            if throughput < before * Self.requiredGain {
                extraStreams = max(0, extraStreams - 1)
                plateauRemaining = Self.plateauWindows
                return extraStreams
            }
        }
        if plateauRemaining > 0 {
            plateauRemaining -= 1
            return extraStreams
        }
        if diskSaturated, extraStreams < Self.maxExtraStreams, throughput > 0 {
            throughputBeforeRaise = throughput
            extraStreams += 1
        }
        return extraStreams
    }
}

/// Samples every resource, names the one holding the run back, and (in Full) tunes disk
/// streams. One per process; started when a config is first applied.
public actor ResourceGovernor {

    public static let shared = ResourceGovernor()

    private var task: Task<Void, Never>?
    private var tuner = AutoTuner()
    private var last: Snapshot?
    private var sinceLog = 0.0
    private var profileIsFull = true
    private var autoTune = true

    /// The most recent report, for the GUI's status.
    public private(set) var latest: ResourceReport?

    /// How often to sample, and how often to write the line to the log.
    public static let sampleInterval: Duration = .seconds(5)
    public static let logIntervalSeconds = 30.0

    private struct Snapshot {
        let time: Double
        let cpuSeconds: Double
        let gpuSeconds: Double
        let bytes: [String: UInt64]
        let ops: Double
    }

    public func configure(for config: Config) {
        profileIsFull = config.resourceProfile == .full
        autoTune = config.resourceAutoTune
        if !(profileIsFull && autoTune) {
            if tuner.extraStreams != 0 { tuner = AutoTuner() }
            ResourceControl.setExtraStreams(0)
        }
    }

    public func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: ResourceGovernor.sampleInterval)
                await self?.tick()
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }

    /// Byte counters keyed by volume id. Not by name: two distinct volumes can report the same
    /// mount name (a symlinked path, a firmlink), and `Dictionary(uniqueKeysWithValues:)`
    /// traps on a duplicate key.
    static func bytesByVolume(_ status: [IOWork.VolumeStatus]) -> [String: UInt64] {
        Dictionary(status.map { ($0.volume, $0.bytes) }, uniquingKeysWith: +)
    }

    /// One sample, report and tuning step. Public for tests and for a GUI that wants a
    /// reading now.
    @discardableResult
    public func tick() async -> ResourceReport? {
        let now = Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
        let memory = await MemoryMonitor.shared.snapshot()
        let status = IOWork.status()
        let current = Snapshot(
          time: now,
          cpuSeconds: Self.processCPUSeconds(),
          gpuSeconds: GPUOps.busySeconds,
          bytes: Self.bytesByVolume(status),
          ops: OperationThroughput.weightedTotal)
        defer { last = current }
        guard let previous = last else { return nil }

        let window = max(current.time - previous.time, 0.001)
        let cores = Double(max(PhysicalCores.count, 1))
        let volumes = status.map { v -> ResourceSample.Volume in
            let delta = v.bytes &- (previous.bytes[v.volume] ?? 0)
            return .init(name: v.name, bytesPerSecond: Double(delta) / window,
                         inFlight: v.inFlight, width: v.width, waiting: v.waiting)
        }
        let sample = ResourceSample(
          windowSeconds: window,
          cpuPercent: min(100, (current.cpuSeconds - previous.cpuSeconds) / window / cores * 100),
          cpuRunning: NativeWork.running,
          cpuWidth: NativeWork.concurrencyLimit,
          cpuWaiting: NativeWork.waiting,
          gpuPercent: min(100, (current.gpuSeconds - previous.gpuSeconds) / window * 100),
          gpuWaiting: GPUOps.waiting,
          volumes: volumes,
          footprintBytes: memory.footprintBytes,
          ledgerBytes: memory.reservedBytes,
          budgetBytes: memory.admissionBudgetBytes,
          memoryWaiting: memory.waiting,
          memoryPressure: memory.underPressure,
          throughputPerMinute: (current.ops - previous.ops) / window * 60)

        let report = ResourceReport.make(from: sample)
        latest = report

        let active = sample.throughputPerMinute > 0
            || volumes.contains { $0.bytesPerSecond > 0 || $0.waiting > 0 }
            || sample.cpuRunning > 0
        sinceLog += window
        if active, sinceLog >= Self.logIntervalSeconds {
            sinceLog = 0
            Log.i(report.line)
        }

        if profileIsFull, autoTune, active {
            var diskSaturated = false
            if case .disk = report.limitedBy { diskSaturated = true }
            let before = tuner.extraStreams
            let extra = tuner.step(throughput: sample.throughputPerMinute,
                                   diskSaturated: diskSaturated,
                                   memoryPressure: sample.memoryPressure)
            if extra != before {
                ResourceControl.setExtraStreams(extra)
                Log.i("auto-tune: \(extra) extra disk stream(s) per volume "
                      + "(throughput \(Int(sample.throughputPerMinute)) weighted ops/min)")
            }
        }
        return report
    }

    /// Star's user + system CPU seconds so far.
    static func processCPUSeconds() -> Double {
        #if canImport(Darwin) || canImport(Glibc)
        var usage = rusage()
        #if canImport(Glibc)
        // Glibc imports RUSAGE_SELF as the `__rusage_who` enum, but getrusage wants its raw Int32.
        let who = __rusage_who_t(RUSAGE_SELF.rawValue)
        #else
        let who = RUSAGE_SELF
        #endif
        guard getrusage(who, &usage) == 0 else { return 0 }
        func seconds(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
        #else
        return 0
        #endif
    }
}
