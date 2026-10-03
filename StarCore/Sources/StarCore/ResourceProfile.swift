import Foundation
import logging
import StarCppBridge
#if canImport(Darwin)
import Darwin
#endif

/// How much of this Mac star may use. One setting that scales every per-resource limit —
/// memory, CPU, GPU, each disk — see `ResourceLimits`. Changes live, mid-run.
public enum ResourceProfile: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Everything the machine has. The default.
    case full
    case balanced
    case light
    /// Every limit is an editable field; see `Config.customResources`.
    case custom

    public var id: Self { self }
}

/// Thread QoS for star's CPU and I/O work, and, through the OpenCV patch, for OpenCV's
/// parallel loops too.
public enum ResourceQoS: String, Codable, CaseIterable, Sendable {
    case userInitiated
    case utility
    case background

    public var qualityOfService: QualityOfService {
        switch self {
        case .userInitiated: .userInitiated
        case .utility: .utility
        case .background: .background
        }
    }

    public var dispatchQoS: DispatchQoS {
        switch self {
        case .userInitiated: .userInitiated
        case .utility: .utility
        case .background: .background
        }
    }
}

/// `setiopolicy_np` throttling class for star's disk work, applied per thread.
public enum ResourceIOPolicy: String, Codable, CaseIterable, Sendable {
    case `default`
    case utility
    case throttle
}

/// The editable half of Custom. Memory fraction and pipeline depth are Custom's too, but
/// they live where they always did (`Config.maxMatMemoryFraction`,
/// `Config.numberOfFramesToProcessConcurrently`) so existing configs and flags keep
/// meaning what they meant.
public struct CustomResourceLimits: Codable, Equatable, Sendable {
    public var cpuWidth: Int
    public var qos: ResourceQoS
    public var gpuWidth: Int
    /// (0, 1]. 1 means no duty-cycle throttling.
    public var gpuDutyCycle: Double
    public var diskStreamsPerVolume: Int
    public var ioPolicy: ResourceIOPolicy

    public init(cpuWidth: Int, qos: ResourceQoS, gpuWidth: Int, gpuDutyCycle: Double,
                diskStreamsPerVolume: Int, ioPolicy: ResourceIOPolicy) {
        self.cpuWidth = cpuWidth
        self.qos = qos
        self.gpuWidth = gpuWidth
        self.gpuDutyCycle = gpuDutyCycle
        self.diskStreamsPerVolume = diskStreamsPerVolume
        self.ioPolicy = ioPolicy
    }

    /// Pre-filled from Full, which is what Custom opens from by default.
    public static var fromFull: CustomResourceLimits {
        let l = ResourceLimits.preset(.full)
        return CustomResourceLimits(cpuWidth: l.cpuWidth, qos: l.qos, gpuWidth: l.gpuWidth,
                                    gpuDutyCycle: l.gpuDutyCycle,
                                    diskStreamsPerVolume: l.diskStreamsPerVolume,
                                    ioPolicy: l.ioPolicy)
    }
}

/// The concrete limits a profile means on this machine. `C` below is
/// `PhysicalCores.count`.
///
/// |                         | Full  | Balanced | Light            |
/// |-------------------------|-------|----------|------------------|
/// | memory budget           | 0.85  | 0.60     | 0.35             |
/// | CPU gate width          | C     | C/2      | max(2, C/4)      |
/// | thread QoS              | userInitiated | utility | background |
/// | GPU gate width          | 8     | 2        | 1                |
/// | GPU duty cycle          | 1     | 1        | 0.5              |
/// | disk streams per volume | 4     | 2        | 1                |
/// | I/O policy              | default | utility | throttle        |
/// | pipeline depth cap      | 4C    | 2C       | C                |
public struct ResourceLimits: Equatable, Sendable {
    public var memoryFraction: Double
    public var cpuWidth: Int
    public var qos: ResourceQoS
    public var gpuWidth: Int
    public var gpuDutyCycle: Double
    public var diskStreamsPerVolume: Int
    public var ioPolicy: ResourceIOPolicy
    public var pipelineDepth: Int

    public static func preset(_ profile: ResourceProfile,
                              cores: Int = PhysicalCores.count) -> ResourceLimits {
        let c = max(1, cores)
        switch profile {
        case .full, .custom:
            return ResourceLimits(memoryFraction: 0.85, cpuWidth: c, qos: .userInitiated,
                                  gpuWidth: 8, gpuDutyCycle: 1.0, diskStreamsPerVolume: 4,
                                  ioPolicy: .default, pipelineDepth: 4 * c)
        case .balanced:
            return ResourceLimits(memoryFraction: 0.60, cpuWidth: max(1, c / 2), qos: .utility,
                                  gpuWidth: 2, gpuDutyCycle: 1.0, diskStreamsPerVolume: 2,
                                  ioPolicy: .utility, pipelineDepth: 2 * c)
        case .light:
            return ResourceLimits(memoryFraction: 0.35, cpuWidth: max(2, c / 4), qos: .background,
                                  gpuWidth: 1, gpuDutyCycle: 0.5, diskStreamsPerVolume: 1,
                                  ioPolicy: .throttle, pipelineDepth: c)
        }
    }
}

extension Config {

    /// The limits in effect: the profile's preset, or for Custom the editable fields.
    public var resources: ResourceLimits {
        switch resourceProfile {
        case .full, .balanced, .light:
            return ResourceLimits.preset(resourceProfile)
        case .custom:
            let custom = customResources
            return ResourceLimits(memoryFraction: maxMatMemoryFraction,
                                  cpuWidth: max(1, custom.cpuWidth),
                                  qos: custom.qos,
                                  gpuWidth: max(1, custom.gpuWidth),
                                  gpuDutyCycle: min(max(custom.gpuDutyCycle, 0.05), 1.0),
                                  diskStreamsPerVolume: max(1, custom.diskStreamsPerVolume),
                                  ioPolicy: custom.ioPolicy,
                                  pipelineDepth: max(1, numberOfFramesToProcessConcurrently))
        }
    }

    /// Fraction of physical memory the ledger may reserve.
    public var effectiveMemoryFraction: Double { resources.memoryFraction }

    /// `OperationQueue` width. Wide by default: with memory doing the admitting, an op
    /// suspended in `MemoryMonitor.reserve` holds no thread.
    public var pipelineDepth: Int { resources.pipelineDepth }

    /// How many frames of work the machine can usefully keep going at once, for sizing
    /// things that scale with it (the keypoint limit's frames term, the resolution advice,
    /// the save monitor, the final-horizon-mask budget). Not the queue width: that is
    /// deliberately several times larger.
    public var frameConcurrency: Int {
        switch resourceProfile {
        case .custom: max(1, numberOfFramesToProcessConcurrently)
        default: max(1, resources.cpuWidth)
        }
    }
}

/// Applies a config's `ResourceLimits` to the process-wide gates. Idempotent and cheap;
/// called whenever the config changes, so every limit moves live.
public enum ResourceControl {

    private static let lock = NSLock()
    nonisolated(unsafe) private static var applied: ResourceLimits?

    public static func apply(_ config: Config) {
        apply(config.resources)
    }

    public static func apply(_ limits: ResourceLimits) {
        lock.lock()
        let changed = applied != limits
        applied = limits
        lock.unlock()

        NativeWork.setLimits(width: limits.cpuWidth, qos: limits.qos)
        IOWork.setLimits(streamsPerVolume: limits.diskStreamsPerVolume,
                         policy: limits.ioPolicy, qos: limits.qos)
        GPUOps.setConcurrency(limits.gpuWidth)
        GPUOps.setDutyCycle(limits.gpuDutyCycle)

        if changed {
            var message = "resources: memory \(Int(limits.memoryFraction * 100))%, "
            message += "CPU width \(limits.cpuWidth) at \(limits.qos.rawValue), "
            message += "GPU width \(limits.gpuWidth) duty \(limits.gpuDutyCycle), "
            message += "\(limits.diskStreamsPerVolume) disk stream(s) per volume "
            message += "(\(limits.ioPolicy.rawValue)), pipeline depth \(limits.pipelineDepth)"
            Log.i(message)
        }
    }

    /// The limits last applied, for the status line.
    public static var current: ResourceLimits? {
        lock.lock(); defer { lock.unlock() }
        return applied
    }
}
