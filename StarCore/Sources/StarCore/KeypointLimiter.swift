import Foundation

/// Bounds how many keypoint operations run at once.
///
/// An *execution* gate, deliberately not a readiness gate.  It used to be enforced from
/// `KeypointOp.isReady`, which deadlocked the pipeline:
///
///   - `isReady` is a KVO-observed `Operation` property, and `OperationQueue` caches
///     what it last observed.  An op that answered "not ready" because the limiter was
///     full was never re-examined, because nothing fires an `isReady` change when a slot
///     frees.  Every keypoint op hangs off the same merged-horizon dependency, so they
///     all became ready at the same instant — all but `max` of them latched not-ready
///     forever.  With `--num-concurrent-renders 1` the limit is 1, so exactly one
///     keypoint op ever ran and the whole run went idle.
///   - Worse, acquiring inside `isReady` charged slots to ops the queue then never
///     started (the queue polls readiness for its own bookkeeping).  Those slots were
///     released by `finish()`, which never ran, so they leaked permanently — a single
///     stray poll could wedge the limiter even once readiness was re-evaluated.
///
/// So the gate moved to where the work actually happens: `acquire()` suspends the op's
/// task, `isReady` stays a pure function of dependencies, and the queue's view of
/// readiness is never a lie.
///
/// `max` is always `<= numberOfFramesToProcessConcurrently`, which is also the frame
/// queue's `maxConcurrentOperationCount` (see `Config.keypointConcurrency`).  That is
/// what makes suspending here safe rather than a different deadlock: waiting ops occupy
/// queue slots, but at least one keypoint op is always running, and it needs nothing
/// from the queue to finish.
final class KeypointLimiter: @unchecked Sendable {
    private let lock = NSLock()
    private var max: Int
    private var current = 0

    private var waiters: [(id: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var nextWaiterId = 0

    /// Waiters cancelled before their continuation was installed.  `onCancel` can run
    /// before the `withCheckedContinuation` body does, so the cancellation has to be
    /// parked somewhere the body will find it.
    private var cancelledBeforeSuspend = Set<Int>()

    init(max: Int) {
        self.max = max
    }

    func set(max: Int) {
        lock.lock()
        self.max = max
        // Raising the limit has to wake anyone already parked; nothing else will.
        let resumable = grantLocked()
        lock.unlock()
        for continuation in resumable { continuation.resume() }
    }

    /// Suspends until a slot is free.  Always pairs with exactly one `release()`,
    /// including when the calling task is cancelled — a cancelled waiter is granted a
    /// slot immediately so it can unwind, and it releases without doing any work.
    func acquire() async {
        let id = claimWaiterId()

        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()

                if cancelledBeforeSuspend.remove(id) != nil {
                    current += 1
                    lock.unlock()
                    continuation.resume()
                    return
                }

                if current < max {
                    current += 1
                    lock.unlock()
                    continuation.resume()
                    return
                }

                waiters.append((id: id, continuation: continuation))
                lock.unlock()
            }
        } onCancel: {
            cancelWaiter(id)
        }

        // `onCancel` can fire after the continuation resumed but before the handler
        // returns, parking a note for a waiter that is already through.  Nothing will
        // ever read it, so drop it here rather than growing the set for the life of
        // the run.
        discardCancelNote(id)
    }

    func release() {
        lock.lock()
        current -= 1
        let resumable = grantLocked()
        lock.unlock()
        for continuation in resumable { continuation.resume() }
    }

    /// In-flight count, for tests and diagnostics.
    var inFlight: Int {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    /// Parked count, for tests and diagnostics.
    var waiting: Int {
        lock.lock()
        defer { lock.unlock() }
        return waiters.count
    }

    // MARK: - Internal

    private func claimWaiterId() -> Int {
        lock.lock()
        defer { lock.unlock() }
        let id = nextWaiterId
        nextWaiterId += 1
        return id
    }

    /// Hand slots to as many parked waiters as now fit.  Caller holds `lock` and must
    /// resume the returned continuations *after* dropping it — resuming under a lock
    /// can re-enter this type on the resumed task's thread.
    private func grantLocked() -> [CheckedContinuation<Void, Never>] {
        var resumable: [CheckedContinuation<Void, Never>] = []
        while current < max, !waiters.isEmpty {
            resumable.append(waiters.removeFirst().continuation)
            current += 1
        }
        return resumable
    }

    /// Let a cancelled waiter through rather than dropping it.  Going briefly over `max`
    /// costs nothing — the op it unblocks checks `Task.isCancelled` and returns without
    /// doing any work — and it keeps `acquire()`/`release()` balanced for every caller,
    /// cancelled or not.
    private func cancelWaiter(_ id: Int) {
        lock.lock()
        if let index = waiters.firstIndex(where: { $0.id == id }) {
            let continuation = waiters.remove(at: index).continuation
            current += 1
            lock.unlock()
            continuation.resume()
            return
        }
        // Not parked yet.  Either it already has its slot (nothing to do) or it is about
        // to suspend, and the body will see this and skip suspending.
        cancelledBeforeSuspend.insert(id)
        lock.unlock()
    }

    private func discardCancelNote(_ id: Int) {
        lock.lock()
        cancelledBeforeSuspend.remove(id)
        lock.unlock()
    }
}
