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
/// Fairness: both kinds of caller wait in ONE queue and are granted strictly in arrival
/// order. Blocking callers used to wait on the condition variable while tasks sat in a
/// separate list that every release served first, so a native thread inside the image
/// loader or a GPU entry point could be passed over indefinitely by a stream of tasks.
///
/// Cancellation: a cancelled waiter is granted a slot rather than dropped, so `acquire()`
/// always answers holding one and the caller's `release()` stays balanced. Going briefly
/// over `max` costs nothing, because a cancelled caller checks `Task.isCancelled` and
/// returns without doing any work.
public final class ResizableGate: @unchecked Sendable {
    private let lock = NSCondition()
    private var limit: Int
    private var held = 0

    /// How a granted waiter is woken, once the lock has been dropped.
    private enum Wake {
        case task(CheckedContinuation<Void, Never>)
        case thread(DispatchSemaphore)

        func fire() {
            switch self {
            case .task(let continuation): continuation.resume()
            case .thread(let semaphore): semaphore.signal()
            }
        }
    }

    private struct Waiter {
        let id: Int
        let wake: Wake
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
        lock.unlock()
        for wake in resumable { wake.fire() }
    }

    /// Blocks the calling thread until a slot is free. For native threads that cannot
    /// suspend; never call it from a cooperative-pool task. Owes one `release()`.
    public func acquireBlocking() {
        lock.lock()
        if held < limit, waiters.isEmpty {
            held += 1
            lock.unlock()
            return
        }
        // Park in the same queue the tasks use. `grantLocked` counts the slot for us before
        // it signals, so there is nothing to re-check on waking.
        let id = nextWaiterId
        nextWaiterId += 1
        let semaphore = DispatchSemaphore(value: 0)
        waiters.append(Waiter(id: id, wake: .thread(semaphore)))
        lock.unlock()
        semaphore.wait()
    }

    /// Suspends until a slot is free. The caller owes exactly one `release()`.
    public func acquire() async {
        let id = claimWaiterId()

        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                if cancelledBeforeSuspend.remove(id) != nil || (held < limit && waiters.isEmpty) {
                    held += 1
                    lock.unlock()
                    continuation.resume()
                    return
                }
                waiters.append(Waiter(id: id, wake: .task(continuation)))
                lock.unlock()
            }
        } onCancel: {
            lock.lock()
            if let index = waiters.firstIndex(where: { $0.id == id }) {
                let wake = waiters.remove(at: index).wake
                held += 1
                lock.unlock()
                wake.fire()
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
        lock.unlock()
        for wake in resumable { wake.fire() }
    }

    /// Run `body` holding a slot.
    public func withSlot<T: Sendable>(_ body: () async throws -> T) async rethrows -> T {
        await acquire()
        defer { release() }
        return try await body()
    }

    /// Caller holds `lock` and resumes the result after dropping it.
    private func grantLocked() -> [Wake] {
        var resumable: [Wake] = []
        while held < limit, !waiters.isEmpty {
            resumable.append(waiters.removeFirst().wake)
            held += 1
        }
        return resumable
    }
}
