import Foundation
import Semaphore
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
/// Deliberately the same `TaskRunner.maxConcurrentTasks` that bounded this work
/// before, so the amount of native work running at once does not change — only
/// which threads it runs on.  Note that each of these operations fans out
/// further inside OpenCV, which selects the GCD backend and ignores
/// `cv::setNumThreads` for values above one (see the comment on
/// `medianMergeTyped` in ImageAligner.cpp), so this bounds the number of
/// concurrent *operations*, not the total thread count.
public enum NativeWork {

    /// Real threads for blocking work.  Concurrent, but only ever handed
    /// `concurrencyLimit` items at a time.
    private static let queue = DispatchQueue(label: "star.native-work",
                                             qos: .userInitiated,
                                             attributes: .concurrent)

    public static let concurrencyLimit = Int(TaskRunner.maxConcurrentTasks)

    private static let slots = AsyncSemaphore(value: concurrencyLimit)

    /// Run `work` on a native thread, suspending the caller until it finishes.
    public static func run<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await slots.wait()
        defer { slots.signal() }
        return await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: work()) }
        }
    }

    /// Throwing variant.
    public static func run<T: Sendable>(
      _ work: @escaping @Sendable () throws -> T
    ) async throws -> T {
        await slots.wait()
        defer { slots.signal() }
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try work()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
}
