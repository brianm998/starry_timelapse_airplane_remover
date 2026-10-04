import Foundation

/// A FIFO gate whose width can change while callers are parked in it, for both kinds of
/// caller: Swift tasks suspend in `acquire()`, and native threads inside a C++ call (the
/// image loader, the GPU entry points) block in `acquireBlocking()`. They share one count,
/// so a width means the same thing to both — `IOWork`'s per-volume streams are read by the
/// loader on a native thread and written by tasks.
///
/// The shape `KeypointLimiter` proved out — an *execution* gate, waited on by suspending
/// rather than blocking, with a live `set(max:)` — without that type's timeout backstop,
/// which belongs to keypoint ops and nothing else. `CPUWork` and `IOWork` are built on it.
///
/// Cancellation: a cancelled waiter is granted a slot rather than dropped, so `acquire()`
/// always answers holding one and the caller's `release()` stays balanced. Going briefly
/// over `max` costs nothing, because a cancelled caller checks `Task.isCancelled` and
/// returns without doing any work.
public final class ResizableGate: @unchecked Sendable {
    private let lock = NSCondition()
    private var limit: Int
    private var held = 0

    private struct Waiter {
        let id: Int
        let continuation: CheckedContinuation<Void, Never>
    }
    private var waiters: [Waiter] = []
    private var nextWaiterId = 0
    /// `onCancel` can run before the `withCheckedContinuation` body does; the
    /// cancellation is parked here for the body to find.
    private var cancelledBeforeSuspend = Set<Int>()

    public init(max: Int) {
        limit = Swift.max(1, max)
    }

    public var max: Int {
        lock.lock(); defer { lock.unlock() }
        return limit
    }

    public var inFlight: Int {
        lock.lock(); defer { lock.unlock() }
        return held
    }

    public var waiting: Int {
        lock.lock(); defer { lock.unlock() }
        return waiters.count
    }

    /// Resize. Raising wakes parked waiters; lowering lets work already inside finish and
    /// admits no one until the count drains below the new width. At least 1.
    public func set(max: Int) {
        lock.lock()
        limit = Swift.max(1, max)
        let resumable = grantLocked()
        lock.broadcast()
        lock.unlock()
        for continuation in resumable { continuation.resume() }
    }

    /// Blocks the calling thread until a slot is free. For native threads that cannot
    /// suspend; never call it from a cooperative-pool task. Owes one `release()`.
    public func acquireBlocking() {
        lock.lock()
        while held >= limit { lock.wait() }
        held += 1
        lock.unlock()
    }

    /// Suspends until a slot is free. The caller owes exactly one `release()`.
    public func acquire() async {
        let id = claimWaiterId()

        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                if cancelledBeforeSuspend.remove(id) != nil || held < limit {
                    held += 1
                    lock.unlock()
                    continuation.resume()
                    return
                }
                waiters.append(Waiter(id: id, continuation: continuation))
                lock.unlock()
            }
        } onCancel: {
            lock.lock()
            if let index = waiters.firstIndex(where: { $0.id == id }) {
                let continuation = waiters.remove(at: index).continuation
                held += 1
                lock.unlock()
                continuation.resume()
            } else {
                // Not parked yet (about to suspend, and will see this), or already through.
                cancelledBeforeSuspend.insert(id)
                lock.unlock()
            }
        }

        // A note parked for a waiter that was already through would otherwise live forever.
        discardCancelNote(id)
    }

    private func claimWaiterId() -> Int {
        lock.lock()
        defer { lock.unlock() }
        let id = nextWaiterId
        nextWaiterId += 1
        return id
    }

    private func discardCancelNote(_ id: Int) {
        lock.lock()
        cancelledBeforeSuspend.remove(id)
        lock.unlock()
    }

    public func release() {
        lock.lock()
        // Never below zero: an extra release would otherwise inflate the width for the
        // rest of the run rather than merely wasting a slot.
        if held > 0 { held -= 1 }
        let resumable = grantLocked()
        lock.broadcast()
        lock.unlock()
        for continuation in resumable { continuation.resume() }
    }

    /// Run `body` holding a slot.
    public func withSlot<T: Sendable>(_ body: () async throws -> T) async rethrows -> T {
        await acquire()
        defer { release() }
        return try await body()
    }

    /// Caller holds `lock` and resumes the result after dropping it.
    private func grantLocked() -> [CheckedContinuation<Void, Never>] {
        var resumable: [CheckedContinuation<Void, Never>] = []
        while held < limit, !waiters.isEmpty {
            resumable.append(waiters.removeFirst().continuation)
            held += 1
        }
        return resumable
    }
}
