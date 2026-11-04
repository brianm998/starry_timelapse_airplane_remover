import Foundation

/// Cancels operation queues without freeing an operation that a running one still points at.
///
/// swift-corelibs-foundation (Linux, Windows) keeps, in every operation, the set of operations
/// that depend on it as *unretained* pointers, and walks that set when the operation finishes.
/// Darwin's Foundation does not.  `cancelAllOperations` makes every queued dependent
/// ready, so each one starts, finishes at once, and is released by its queue: freed, while the
/// operation it depends on is still running and still lists it.  When that operation then
/// finishes it touches the freed dependent, and the process dies of SIGSEGV inside
/// `AsyncOperation.finish()`.  That was the crash `uiStartDuringRun` hit on ubuntu (a start
/// during a run stops the run), and the signature BUG-005 records.
///
/// This holds every operation a stop cancels until each has nothing unfinished left to depend
/// on, so none is freed while an operation that lists it can still finish.
final class CancelledOperationKeeper: @unchecked Sendable {
    private let lock = NSLock()
    private var held: [Operation] = []

    /// Holds what is on `queues` now, then cancels it all.
    func cancelAll(on queues: [OperationQueue]) {
        // Held before the cancel: afterwards the queues start letting the operations go.
        let operations = queues.flatMap { $0.operations }
        lock.lock()
        release()
        held.append(contentsOf: operations)
        lock.unlock()
        queues.forEach { $0.cancelAllOperations() }
    }

    /// Lets go of what no unfinished operation can reach any more.
    func purge() {
        lock.lock()
        release()
        lock.unlock()
    }

    /// How many operations are being held (for tests).
    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return held.count
    }

    // Callers hold the lock.  An operation is safe to drop once everything it depends on has
    // finished: those are the only operations that point at it.
    private func release() {
        held.removeAll { operation in
            operation.dependencies.allSatisfy { $0.isFinished }
        }
    }
}
