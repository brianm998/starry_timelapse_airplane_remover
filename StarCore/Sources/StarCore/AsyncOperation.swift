import Foundation

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
    ///   - type: The operation type, which determines the memory multiplier.
    ///   - rawImageBytes: Bytes in one uncompressed source frame.
    ///     Pass `Config.imageWidth × imageHeight × imageBytesPerPixel`.
    ///     Zero (the default) disables memory reservation for this op.
    public init(for type: OperationType, rawImageBytes: UInt64 = 0) {
        self.type = type
        self.estimatedMemoryBytes = rawImageBytes * type.memoryMultiplier
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
            // Reserve memory budget so the scheduler doesn't start more ops
            // than RAM can support.
            if memBytes > 0 {
                await MemoryMonitor.shared.reserve(bytes: memBytes)
            }

            await self.asyncExecute()

            // Release reservation, then mark complete so the queue can start
            // the next operation.
            if memBytes > 0 {
                await MemoryMonitor.shared.release(bytes: memBytes)
            }
            self.finish()
        }
    }

    /// Subclasses implement their async work here.  No need to call `finish()`
    /// or manage the `task` property — `start()` handles both.
    open func asyncExecute() async {
        fatalError("Subclasses must implement asyncExecute()")
    }

    public func finish() {
        state = .finished
        Task { @MainActor in
            frameGraphViewModel.doneWithOperation(ofType: type)
        }
    }
}
