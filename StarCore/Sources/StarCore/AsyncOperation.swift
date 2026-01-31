import Foundation

public class AsyncOperation: Operation {
    private let stateQueue = DispatchQueue(label: "async.op.state")

    private var _isExecuting = false
    private var _isFinished = false

    internal var task: Task<Void, Never>?
    
    override public var isAsynchronous: Bool { true }

    override public var isExecuting: Bool {
        get { stateQueue.sync { _isExecuting } }
        set {
            willChangeValue(forKey: "isExecuting")
            stateQueue.sync { _isExecuting = newValue }
            didChangeValue(forKey: "isExecuting")
        }
    }

    override public var isFinished: Bool {
        get { stateQueue.sync { _isFinished } }
        set {
            willChangeValue(forKey: "isFinished")
            stateQueue.sync { _isFinished = newValue }
            didChangeValue(forKey: "isFinished")
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
