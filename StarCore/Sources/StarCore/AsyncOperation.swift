import Foundation
import StarCoreC
import logging

/// Set to sample each operation's actual peak memory and log it against what the op
/// reserved. Off by default: it spawns one polling task per operation.
///
/// This exists so the per-op multipliers in `Config` can be derived from measurement
/// rather than guessed. Run with concurrency 1 (`--num-concurrent-renders 1`) so the
/// process-wide footprint delta is attributable to a single op, and read the
/// `actual/reserved` ratios out of the log.
public nonisolated(unsafe) var logOperationMemory = false

open class AsyncOperation: Operation, @unchecked Sendable {

    internal enum State: String {
        case ready
        case executing
        case finished

        var keyPath: String { "is" + rawValue.capitalized }
    }

    private let stateLock = NSLock()

    internal let type: OperationType

    /// Bytes of memory budget to reserve before this op's heavy work begins.
    /// Computed as `rawImageBytes × type.memoryMultiplier` at init time.
    /// Zero means no reservation is made (op is considered low-memory).
    public let estimatedMemoryBytes: UInt64

    /// The live Task for this operation.  Assigned by `start()`.
    public private(set) var task: Task<Void, Never>?

    private var _state: State = .ready

    private var state: State {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return _state
        }
        set {
            // Capture old key path BEFORE the assignment so both will/did
            // notifications fire for the correct (old vs new) KVO keys.
            // Reading state.keyPath after _state = newValue would yield the
            // new key for both calls, leaving the old key's didChange unsent
            // and breaking OperationQueue's concurrent-slot tracking.
            let oldKeyPath = state.keyPath
            let newKeyPath = newValue.keyPath

            willChangeValue(forKey: newKeyPath)
            willChangeValue(forKey: oldKeyPath)

            stateLock.lock()
            _state = newValue
            stateLock.unlock()

            didChangeValue(forKey: oldKeyPath)
            didChangeValue(forKey: newKeyPath)
        }
    }

    /// - Parameters:
    ///   - type: The operation type, which provides the default memory multiplier.
    ///   - rawImageBytes: Bytes in one uncompressed source frame.
    ///     Pass `Config.imageWidth × imageHeight × imageBytesPerPixel`.
    ///     Zero (the default) disables memory reservation for this op.
    ///   - memoryMultiplier: Override for the per-type default multiplier.
    ///     Pass `UInt64(config.keypointMemoryMultiplier)` etc. to use config-driven values.
    public init(for type: OperationType, rawImageBytes: UInt64 = 0, memoryMultiplier: UInt64? = nil) {
        self.type = type
        self.estimatedMemoryBytes = rawImageBytes * (memoryMultiplier ?? type.memoryMultiplier)
        Task { @MainActor in
            frameGraphViewModel.queuedOperation(ofType: type)
        }
    }

    override public var isReady: Bool {
        super.isReady && state == .ready
    }

    override public var isExecuting: Bool {
        state == .executing
    }

    override public var isFinished: Bool {
        state == .finished
    }

    override public var isAsynchronous: Bool {
        true
    }

    override public func cancel() {
        super.cancel()
        task?.cancel()
    }

    override public func start() {
        if isCancelled {
            finish()
            return
        }

        state = .executing
        Task { @MainActor in
            frameGraphViewModel.runningOperation(ofType: type)
        }

        let memBytes = estimatedMemoryBytes
        task = Task {
            // Op-type-specific concurrency gate (the keypoint limiter, today).
            //
            // Ahead of the reservation on purpose: an op parked here holds no memory
            // budget.  Reserving first would have a queue full of waiting keypoint ops
            // sitting on gigabytes of reservation that nothing is using, starving every
            // other op type of budget.
            //
            // Also note where this is *not*: gating readiness instead of execution is
            // what wedged the keypoint phase — see `KeypointLimiter`.
            await self.acquireExecutionSlot()

            // Reserve memory budget so the scheduler doesn't start more ops
            // than RAM can support.
            if memBytes > 0 {
                await MemoryMonitor.shared.reserve(bytes: memBytes)
            }

            let probe = logOperationMemory ? MemoryProbe(type: self.type,
                                                         name: self.name,
                                                         reserved: memBytes)
                                           : nil
            await self.asyncExecute()
            await probe?.finish()

            // Release reservation, then mark complete so the queue can start
            // the next operation.
            if memBytes > 0 {
                await MemoryMonitor.shared.release(bytes: memBytes)
            }
            await self.releaseExecutionSlot()
            self.finish()
        }
    }

    /// Subclasses implement their async work here.  No need to call `finish()`
    /// or manage the `task` property — `start()` handles both.
    open func asyncExecute() async {
        fatalError("Subclasses must implement asyncExecute()")
    }

    /// Awaited before this op reserves memory or does any work.  Override to gate a
    /// class of ops on something narrower than the queue's own concurrency limit.
    ///
    /// Every call is balanced by exactly one `releaseExecutionSlot()`, so an override
    /// may take a slot unconditionally.  Default: no gate.
    open func acquireExecutionSlot() async {}

    /// Balances `acquireExecutionSlot()`.  Default: nothing to release.
    open func releaseExecutionSlot() async {}

    public func finish() {
        state = .finished
        Task { @MainActor in
            frameGraphViewModel.doneWithOperation(ofType: type)
        }
    }
}
