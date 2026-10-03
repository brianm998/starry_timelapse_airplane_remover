import Foundation
import logging

/// Runs blocking native work — OpenCV, and the C++ bridge generally — off
/// Swift's cooperative thread pool.
///
/// ## Why this exists
///
/// The per-frame workers (`FrameAlignmentProcessor`, `FrameHorizonProcessor`,
/// `FrameOutlierProcessor`) are actors, so their methods run on the
/// cooperative pool, which is sized to the core count.  Calling straight into
/// OpenCV from one of those methods parks a cooperative thread for as long as
/// the operation takes — seconds for a homography, minutes for a full-res
/// aligned merge.  The pool has no way to grow to compensate: it is built on
/// the assumption that threads yield at suspension points rather than block,
/// and a blocked cooperative thread is simply gone until the C++ returns.
///
/// That is what `TaskRunner.maxConcurrentTasks` has been holding back, with
/// the note "getting this number right is hard / too big and the swift runtime
/// barfs underneath".  The barfing is the pool starving.  Capping frame
/// concurrency at three quarters of the core count keeps enough threads free
/// that the runtime limps on, but it makes an unrelated tuning knob
/// load-bearing for the runtime's health, and it costs throughput on every
/// machine to buy headroom for the worst case.
///
/// ## What it does
///
/// `run` suspends the calling task, hands the closure to a private concurrent
/// `DispatchQueue`, and resumes when it returns.  The cooperative thread is
/// released at the suspension rather than held, so the pool stays free for the
/// async plumbing — progress callbacks, actor hops, file I/O — that has to keep
/// moving while a merge is grinding.
///
/// Admission is gated by an `AsyncSemaphore` *before* dispatching, which is the
/// part that is easy to get wrong.  Bounding by blocking inside the queue
/// instead would defeat the purpose twice over: libdispatch spawns another
/// worker whenever one of its workers blocks, so a semaphore waited on inside
/// the queue produces exactly the thread explosion it was meant to prevent.
/// Waiting asynchronously first means at most `concurrencyLimit` work items are
/// ever in flight, so the queue never needs more threads than that.
///
/// ## The limit
///
/// The CPU gate of the resource profile (`ResourceLimits.cpuWidth`): its width and the QoS
/// its items run at are set by `ResourceControl.apply` and change while the run is going.
/// A change lets items already running finish under the old values and gives new ones the
/// new. Note that each of these operations fans out further inside OpenCV, whose GCD
/// backend ignores `cv::setNumThreads` for values above one (see the comment on
/// `medianMergeTyped` in ImageAligner.cpp) — so this bounds the number of concurrent
/// *operations*, not the total thread count, and the QoS reaches OpenCV's workers only
/// through the `DISPATCH_APPLY_AUTO` patch in `opencv/build.sh`.
///
/// Also available as `CPUWork`.
public enum NativeWork {

    /// Real threads for blocking work.  Concurrent, but only ever handed
    /// `gate.max` items at a time.
    private static let queue = DispatchQueue(label: "star.native-work",
                                             qos: .userInitiated,
                                             attributes: .concurrent)

    static let gate = ResizableGate(max: PhysicalCores.count)

    private static let qosLock = NSLock()
    nonisolated(unsafe) private static var qos: DispatchQoS = .userInitiated

    /// Current width, for logs and the governor.
    public static var concurrencyLimit: Int { gate.max }

    /// Items waiting for a CPU slot.
    public static var waiting: Int { gate.waiting }

    /// Items running.
    public static var running: Int { gate.inFlight }

    /// Seconds of wall time spent inside the gate across all items, for the governor.
    public static var busySeconds: Double { busy.seconds }
    private static let busy = BusyClock()

    public static func setLimits(width: Int, qos newQoS: ResourceQoS) {
        gate.set(max: width)
        qosLock.withLock { qos = newQoS.dispatchQoS }
    }

    private static var currentQoS: DispatchQoS { qosLock.withLock { qos } }

    /// Run `work` on a native thread, suspending the caller until it finishes.
    public static func run<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await gate.acquire()
        defer { gate.release() }
        let itemQoS = currentQoS
        return await withCheckedContinuation { continuation in
            queue.async(qos: itemQoS, flags: .enforceQoS) {
                continuation.resume(returning: busy.measure(work))
            }
        }
    }

    /// Throwing variant.
    public static func run<T: Sendable>(
      _ work: @escaping @Sendable () throws -> T
    ) async throws -> T {
        await gate.acquire()
        defer { gate.release() }
        let itemQoS = currentQoS
        return try await withCheckedThrowingContinuation { continuation in
            queue.async(qos: itemQoS, flags: .enforceQoS) {
                do { continuation.resume(returning: try busy.measure(work)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
}

public typealias CPUWork = NativeWork

/// Accumulates the wall time work items spend running, across threads.
final class BusyClock: @unchecked Sendable {
    private let lock = NSLock()
    private var nanoseconds: UInt64 = 0

    var seconds: Double { Double(lock.withLock { nanoseconds }) / 1_000_000_000 }

    func measure<T>(_ work: () throws -> T) rethrows -> T {
        let start = DispatchTime.now().uptimeNanoseconds
        defer {
            let used = DispatchTime.now().uptimeNanoseconds - start
            lock.withLock { nanoseconds &+= used }
        }
        return try work()
    }

    func add(_ used: UInt64) { lock.withLock { nanoseconds &+= used } }
}
