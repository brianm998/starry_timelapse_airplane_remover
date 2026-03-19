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
    public var task: Task<Void, any Error>?

    private var _state: State = .ready

    private var state: State {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return _state
        }
        set {
            willChangeValue(forKey: newValue.keyPath)
            willChangeValue(forKey: state.keyPath)

            stateLock.lock()
            _state = newValue
            stateLock.unlock()

            didChangeValue(forKey: state.keyPath)
            didChangeValue(forKey: newValue.keyPath)
        }
    }

    public init(for type: OperationType) {
        self.type = type
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

    public func setExecuting() {
        state = .executing
    }
    
    override public func start() {
        if isCancelled {
            self.finish()
            return
        }

        state = .executing
        Task { @MainActor in
            frameGraphViewModel.runningOperation(ofType: type)
        }
        execute()
    }

    open func execute() {
        fatalError("Subclasses must implement execute()")
    }

    public func finish() {
        state = .finished
        Task { @MainActor in
            frameGraphViewModel.doneWithOperation(ofType: type)
        }
    }
}
