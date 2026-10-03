import Foundation
import logging
#if canImport(Darwin)
import Darwin
#endif

/// Gates full-size reads and writes, one gate per volume.
///
/// Storage is a resource star did not model, and on anything slower than an internal NVMe
/// it bounds the merge phase: a USB SSD moved ~200MB/s however many frames were in flight.
/// Without a gate every op that wants a file just goes, and the disk's queue is the
/// scheduler. Source, temp and output can be three different volumes, so each gets its
/// own width — one slow disk must not hold the others back.
///
/// Gates are acquired where the resource is used, not around whole ops: a merge op reads
/// (disk), then merges (GPU), then saves (disk), and holding a disk slot through its GPU
/// phase would waste it. Only the file operation itself is inside a slot, so a slot is
/// never held while waiting on anything else, which is why this cannot deadlock.
///
/// Two ways in, one count per volume:
///   - `run` for Swift tasks. Suspends for a slot, then does the work on a private
///     concurrent queue — off the cooperative pool, which a multi-second decode or save
///     would otherwise starve.
///   - `runBlocking` for native threads already inside a C++ call, namely the image
///     loader behind `image_cache_load`. It blocks the thread in the gate.
public enum IOWork {

    private static let queue = DispatchQueue(label: "star.io-work",
                                             qos: .userInitiated,
                                             attributes: .concurrent)

    private static let lock = NSLock()
    nonisolated(unsafe) private static var streams = 4
    nonisolated(unsafe) private static var policy: ResourceIOPolicy = .default
    nonisolated(unsafe) private static var qos: DispatchQoS = .userInitiated
    nonisolated(unsafe) private static var gates: [String: ResizableGate] = [:]
    nonisolated(unsafe) private static var directoryVolumes: [String: String] = [:]
    nonisolated(unsafe) private static var counters: [String: VolumeCounters] = [:]

    private final class VolumeCounters {
        var bytes: UInt64 = 0
    }

    public static func setLimits(streamsPerVolume: Int, policy newPolicy: ResourceIOPolicy,
                                 qos newQoS: ResourceQoS) {
        lock.lock()
        streams = max(1, streamsPerVolume)
        policy = newPolicy
        qos = newQoS.dispatchQoS
        let all = Array(gates.values)
        let width = streams
        lock.unlock()
        for gate in all { gate.set(max: width) }
    }

    /// The volume a path lives on: the device number of its directory, cached. Paths that
    /// cannot be resolved (not yet created) share one key rather than each making a gate.
    static func volume(of path: String) -> String {
        let directory = (path as NSString).deletingLastPathComponent
        lock.lock()
        if let known = directoryVolumes[directory] {
            lock.unlock()
            return known
        }
        lock.unlock()

        var id = "unknown"
        if let attributes = try? FileManager.default.attributesOfItem(
             atPath: directory.isEmpty ? "." : directory),
           let device = attributes[.systemNumber] as? NSNumber
        {
            id = "dev\(device)"
        }
        lock.lock()
        directoryVolumes[directory] = id
        lock.unlock()
        return id
    }

    static func gate(forVolume volume: String) -> ResizableGate {
        lock.lock()
        defer { lock.unlock() }
        if let gate = gates[volume] { return gate }
        let gate = ResizableGate(max: streams)
        gates[volume] = gate
        return gate
    }

    private static func snapshot() -> (ResourceIOPolicy, DispatchQoS) {
        lock.withLock { (policy, qos) }
    }

    /// Run `work` against a file on `path`'s volume, holding one of that volume's streams.
    /// `bytes` is the size moved, counted per volume for the governor.
    public static func run<T: Sendable>(
      path: String,
      bytes: Int = 0,
      _ work: @escaping @Sendable () throws -> T
    ) async throws -> T {
        let volumeID = volume(of: path)
        let gate = gate(forVolume: volumeID)
        await gate.acquire()
        defer { gate.release() }
        let (ioPolicy, itemQoS) = snapshot()
        let result: T = try await withCheckedThrowingContinuation { continuation in
            queue.async(qos: itemQoS, flags: .enforceQoS) {
                do {
                    continuation.resume(returning: try withThreadPolicy(ioPolicy, work))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        record(volume: volumeID, bytes: bytes)
        return result
    }

    /// Non-throwing variant.
    public static func run<T: Sendable>(
      path: String,
      bytes: Int = 0,
      _ work: @escaping @Sendable () -> T
    ) async -> T {
        let volumeID = volume(of: path)
        let gate = gate(forVolume: volumeID)
        await gate.acquire()
        defer { gate.release() }
        let (ioPolicy, itemQoS) = snapshot()
        let result: T = await withCheckedContinuation { continuation in
            queue.async(qos: itemQoS, flags: .enforceQoS) {
                continuation.resume(returning: withThreadPolicy(ioPolicy, work))
            }
        }
        record(volume: volumeID, bytes: bytes)
        return result
    }

    /// For a native thread inside a C++ call. Blocks for a stream on `path`'s volume, and
    /// runs `work` on the calling thread.
    public static func runBlocking<T>(path: String, bytes: Int = 0, _ work: () -> T) -> T {
        let volumeID = volume(of: path)
        let gate = gate(forVolume: volumeID)
        gate.acquireBlocking()
        defer { gate.release() }
        let (ioPolicy, _) = snapshot()
        let result = withThreadPolicy(ioPolicy, work)
        record(volume: volumeID, bytes: bytes)
        return result
    }

    /// Bytes moved per volume since launch, and the streams in use and waiting.
    public struct VolumeStatus: Sendable {
        public let volume: String
        public let bytes: UInt64
        public let inFlight: Int
        public let waiting: Int
        public let width: Int
    }

    public static func status() -> [VolumeStatus] {
        lock.lock()
        defer { lock.unlock() }
        return gates.map { volume, gate in
            VolumeStatus(volume: volume, bytes: counters[volume]?.bytes ?? 0,
                         inFlight: gate.inFlight, waiting: gate.waiting, width: gate.max)
        }
    }

    private static func record(volume: String, bytes: Int) {
        guard bytes > 0 else { return }
        lock.lock()
        let c = counters[volume] ?? VolumeCounters()
        c.bytes &+= UInt64(bytes)
        counters[volume] = c
        lock.unlock()
    }

    /// Runs `work` with this thread's disk I/O policy set, and restores it after.
    private static func withThreadPolicy<T>(_ policy: ResourceIOPolicy, _ work: () throws -> T) rethrows -> T {
        #if canImport(Darwin)
        if policy != .default {
            let value: Int32 = policy == .utility ? IOPOL_UTILITY : IOPOL_THROTTLE
            setiopolicy_np(IOPOL_TYPE_DISK, IOPOL_SCOPE_THREAD, value)
            defer { setiopolicy_np(IOPOL_TYPE_DISK, IOPOL_SCOPE_THREAD, IOPOL_DEFAULT) }
            return try work()
        }
        #endif
        return try work()
    }
}
