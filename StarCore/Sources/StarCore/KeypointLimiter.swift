import Foundation
import logging

/// Bounds how many keypoint detections run at once, wherever they are driven from.
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
/// So there is one way in for everyone now: `acquire()` suspends the caller.  `isReady`
/// stays a pure function of dependencies and the queue's view of readiness is never a
/// lie, while callers that are not operations at all — the homography fallback, which
/// re-runs detection outside any `KeypointOp` — wait on exactly the same gate.
///
/// Suspending an operation here is safe rather than a different deadlock because `max`
/// is always `<= numberOfFramesToProcessConcurrently` (see `Config.keypointConcurrency`),
/// which is also the frame queue's `maxConcurrentOperationCount`.  So the queue can
/// never be filled entirely by ops parked here: at least one slot holder is always
/// running, whether that is a `KeypointOp` or a self-gating homography fallback, and
/// neither needs anything from the queue in order to finish.
///
/// Public so the gating behaviour can be exercised directly, alongside MemoryMonitor.
public final class KeypointLimiter: @unchecked Sendable {
    private let lock = NSLock()
    private var max: Int
    private var current = 0

    private struct Waiter {
        let id: Int
        let continuation: CheckedContinuation<Bool, Never>
        let deadline: Date
    }

    private var waiters: [Waiter] = []
    private var nextWaiterId = 0

    /// Waiters cancelled before their continuation was installed.  `onCancel` can run
    /// before the `withCheckedContinuation` body does, so the cancellation has to be
    /// parked somewhere the body will find it.
    private var cancelledBeforeSuspend = Set<Int>()

    /// Sweeps for waiters past their deadline.  One task for all of them, running only
    /// while somebody is parked — the same shape as `MemoryMonitor`'s poll task.  It is
    /// not how a waiter normally wakes: `release()` hands slots over directly and
    /// immediately, so this only ever fires on the pathological path.
    private var timeoutSweeper: Task<Void, Never>?
    private static let sweepInterval: Duration = .seconds(1)

    public init(max: Int) {
        self.max = max
    }

    public func set(max: Int) {
        lock.lock()
        self.max = max
        // Raising the limit has to wake anyone already parked; nothing else will.
        let resumable = grantLocked()
        lock.unlock()
        for continuation in resumable { continuation.resume(returning: true) }
    }

    /// Suspends until a slot is free.
    ///
    /// Returns true when a slot was taken, and the caller owes exactly one `release()`.
    /// Returns false only when the wait timed out: the caller then holds nothing, must
    /// not release, and proceeds ungated.
    ///
    /// Bounded, and proceeding with a warning beats waiting forever, on the same
    /// reasoning as `MemoryMonitor`'s forced admission: slots are only ever held by work
    /// that does finish, so a genuine wait should be short — but hanging the pipeline
    /// would be worse than briefly exceeding the cap.
    ///
    /// A cancelled waiter is granted a slot rather than dropped, so `acquire()` still
    /// answers true and the caller's release path stays balanced whether it was
    /// cancelled or not.  Going briefly over `max` costs nothing there: a cancelled
    /// caller checks `Task.isCancelled` and returns without doing any work.
    @discardableResult
    public func acquire(timeout: TimeInterval = 300) async -> Bool {
        let id = claimWaiterId()

        let granted = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                lock.lock()

                if cancelledBeforeSuspend.remove(id) != nil {
                    current += 1
                    lock.unlock()
                    continuation.resume(returning: true)
                    return
                }

                if current < max {
                    current += 1
                    lock.unlock()
                    continuation.resume(returning: true)
                    return
                }

                waiters.append(Waiter(id: id,
                                      continuation: continuation,
                                      deadline: Date().addingTimeInterval(timeout)))
                lock.unlock()

                startSweeperIfNeeded()
            }
        } onCancel: {
            cancelWaiter(id)
        }

        // `onCancel` can fire after the continuation resumed but before the handler
        // returns, parking a note for a waiter that is already through.  Nothing will
        // ever read it, so drop it here rather than growing the set for the life of
        // the run.
        discardCancelNote(id)

        return granted
    }

    public func release() {
        lock.lock()
        // Never below zero: an extra release would otherwise inflate the cap for the
        // rest of the run rather than merely wasting a slot.
        if current > 0 { current -= 1 }
        let resumable = grantLocked()
        lock.unlock()
        for continuation in resumable { continuation.resume(returning: true) }
    }

    /// In-flight count, for tests and diagnostics.
    public var inFlight: Int {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    /// Parked count, for tests and diagnostics.
    public var waiting: Int {
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
    private func grantLocked() -> [CheckedContinuation<Bool, Never>] {
        var resumable: [CheckedContinuation<Bool, Never>] = []
        while current < max, !waiters.isEmpty {
            resumable.append(waiters.removeFirst().continuation)
            current += 1
        }
        return resumable
    }

    private func cancelWaiter(_ id: Int) {
        lock.lock()
        if let index = waiters.firstIndex(where: { $0.id == id }) {
            let continuation = waiters.remove(at: index).continuation
            current += 1
            lock.unlock()
            continuation.resume(returning: true)
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

    private func startSweeperIfNeeded() {
        lock.lock()
        defer { lock.unlock() }
        guard timeoutSweeper == nil, !waiters.isEmpty else { return }
        timeoutSweeper = Task { [weak self] in
            while true {
                try? await Task.sleep(for: KeypointLimiter.sweepInterval)
                guard let self, self.sweepOnce() else { break }
            }
        }
    }

    /// One sweep: time out anyone past their deadline, and say whether to sweep again.
    ///
    /// Deciding to stop and clearing `timeoutSweeper` happen under the same lock
    /// acquisition that reads `waiters`.  Splitting them would leave a window where a
    /// waiter parks, sees a non-nil sweeper and so does not start one, and then has its
    /// sweeper cleared out from under it — parked with no timeout backstop.
    private func sweepOnce() -> Bool {
        let now = Date()

        lock.lock()
        var expired: [CheckedContinuation<Bool, Never>] = []
        var remaining: [Waiter] = []
        for waiter in waiters {
            if now >= waiter.deadline {
                expired.append(waiter.continuation)
            } else {
                remaining.append(waiter)
            }
        }
        waiters = remaining
        let cap = max
        let keepSweeping = !waiters.isEmpty
        if !keepSweeping { timeoutSweeper = nil }
        lock.unlock()

        if !expired.isEmpty {
            // Deliberately not "something holding a slot is not completing", which is what
            // this said and which sent a real diagnosis down the wrong path. The ops were
            // completing fine; the machine was too loaded for them to finish quickly. At
            // 32.7MP a healthy keypoint op measured 21.8s min / 50.4s median / 195s max
            // over 312 of them, so 300s means slot holders have slowed by several times —
            // and on a machine that is out of memory, adding an ungated op is the last
            // thing that helps. `MemoryMonitor` is what stops it doing real harm: an
            // ungated op still has to reserve its 7.8GB, and cannot while the machine is
            // full. The cap being exceeded here is a queue-depth statement, not a
            // memory-safety one.
            Log.w("KeypointLimiter: \(expired.count) waiter(s) hit their deadline and are " +
                  "proceeding ungated — the \(cap)-op cap will be exceeded until they " +
                  "finish, though the memory gate still applies to each of them. Either a " +
                  "slot holder is genuinely stuck, or the machine is loaded enough that " +
                  "ops which normally take under a minute are taking more than five. " +
                  "Check the MemoryMonitor lines above for which.")
        }
        // Timed-out waiters hold no slot, so they must not release one.
        for continuation in expired { continuation.resume(returning: false) }

        return keepSweeping
    }
}
