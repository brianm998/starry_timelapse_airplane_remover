import Foundation

public class AsyncOperation: Operation, @unchecked Sendable {
    private let stateQueue = DispatchQueue(label: "async.op.state")

    private var _isExecuting = false
    private var _isFinished = false

    internal var task: Task<Void, any Error>?
    
    override public var isAsynchronous: Bool { true }

    private let type: OperationType

    public init(for type: OperationType) {
        self.type = type
        Task { @MainActor in
            frameGraphViewModel.queuedOperation(ofType: type)
        }
    }
    
    override public var isExecuting: Bool {
        get { stateQueue.sync { _isExecuting } }
        set {
            willChangeValue(forKey: "isExecuting")
            stateQueue.sync { _isExecuting = newValue }
            didChangeValue(forKey: "isExecuting")
            if isExecuting {
                Task { @MainActor in
                    frameGraphViewModel.runningOperation(ofType: type)
                }
            }            
        }
    }

    override public var isFinished: Bool {
        get { stateQueue.sync { _isFinished } }
        set {
            willChangeValue(forKey: "isFinished")
            stateQueue.sync { _isFinished = newValue }
            didChangeValue(forKey: "isFinished")
            if isFinished {
                Task { @MainActor in
                    frameGraphViewModel.doneWithOperation(ofType: type)
                }
            }
        }
    }

    override public func start() {
        if isCancelled {
            isFinished = true
            return
        }
        isExecuting = true
        execute()
    }

    override public func cancel() {
        super.cancel()
        task?.cancel()
    }

    func execute() {
        fatalError("override")
    }

    func finish() {
        isExecuting = false
        isFinished = true
    }
}
