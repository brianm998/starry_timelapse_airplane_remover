import Foundation
import logging
import Semaphore

// an alternative to task groups, looking for thread stability

fileprivate var numberRunning = NumberRunning()

public class TaskRunner {
    // XXX getting this number right is hard
    // too big and the swift runtime barfs underneath
    // too small and the process runs without available cpu resources
    public static var maxConcurrentTasks: UInt = determineMax() {
        didSet {
            Log.i("using maximum of \(maxConcurrentTasks) concurrent tasks")
        }
    }

    //private var allowedToRun
    //private var closures: [ClosureType] = []
    
}

fileprivate func determineMax() -> UInt {
    var numProcessors = ProcessInfo.processInfo.activeProcessorCount
    numProcessors -= numProcessors/4
    if numProcessors < 2 { numProcessors = 2 }
    return UInt(numProcessors)
}

public actor Counter {
    private var number: Int = 0

    public init() { }
    
    public func nextNumber() -> Int {
        let ret = number
        number += 1
        return ret
    }
}

fileprivate let counter = Counter()

public actor TaskEnabler {
    public let priority: TaskPriority
    private let semaphore = AsyncSemaphore(value: 0)
    public let number: Int
    
    public init(priority: TaskPriority) async {
        self.priority = priority
        self.number = await counter.nextNumber()
        Log.d("created task enabler #\(number)")
    }

    public func wait() async {
        Log.d("task enabler #\(number) waiting")
        await semaphore.wait()
        Log.d("task enabler #\(number) done waiting")
    }
    
    public func enable() {
        Log.d("task enabler #\(number) signal")
        semaphore.signal()
    }
}

public actor TaskMaster {

    private var highPrioTasks: [TaskEnabler] = []
    private var mediumPrioTasks: [TaskEnabler] = []
    private var lowPrioTasks: [TaskEnabler] = []

    public func register(_ enabler: TaskEnabler) async {
        if await numberRunning.startOnIncrement(to: TaskRunner.maxConcurrentTasks) {
            await enabler.enable()
        } else {
            switch enabler.priority {
            case .userInitiated:
                highPrioTasks.append(enabler)
            case .utility:
                lowPrioTasks.append(enabler)
            case .background:
                lowPrioTasks.append(enabler)
            case .high:
                highPrioTasks.append(enabler)
            case .medium:
                mediumPrioTasks.append(enabler)
            case .low:
                lowPrioTasks.append(enabler)
            default:
                lowPrioTasks.append(enabler)
            }
        }
    }
    
    public func enableTask() async {
        while await numberRunning.startOnIncrement(to: TaskRunner.maxConcurrentTasks) {
            if highPrioTasks.count > 0 {
                await highPrioTasks.removeFirst().enable()
            } else if mediumPrioTasks.count > 0 {
                await mediumPrioTasks.removeFirst().enable()
            } else if lowPrioTasks.count > 0 {
                await lowPrioTasks.removeFirst().enable()
            } else {
                await numberRunning.decrement()
            }
        }
    }
}

public let taskMaster = TaskMaster()

/**
 var tasks: [Task<ValueDistribution,Never>] = []
 let task = await runTask() {
 // do something
 return valueDistribution 
 }
 tasks.append(task)
 for task in tasks {
 let response = await task.value
 // handle each response
 }
 */
public func runTask<Type>(at priority: TaskPriority = .medium,
                          _ closure: @escaping () async -> Type) async -> Task<Type,Never>
{
    let enabler = await TaskEnabler(priority: priority)
    await taskMaster.register(enabler)
    await enabler.wait()
    Log.d("task enabler #\(enabler.number) returning closure")
    return Task<Type,Never> {
        Log.d("task enabler #\(enabler.number) running closure")
        let ret = await closure() // run closure in separate task
        Log.d("task enabler #\(enabler.number) about to decrement number running")
        await numberRunning.decrement()
        Log.d("task enabler #\(enabler.number) decremented number running")
        return ret
    }
}

/**
 var tasks: [Task<ValueDistribution,Error>] = []
 let task = try await runThrowingTask() {
 // do something
 return valueDistribution 
 }
 tasks.append(task)
 for task in tasks {
 let response = try await task.value
 // handle each response
 }
 */
public func runThrowingTask<Type>(at priority: TaskPriority,
                                  _ closure: @escaping () async throws -> Type)
  async throws -> Task<Type,Error>
{
    let enabler = await TaskEnabler(priority: priority)
    await taskMaster.register(enabler)
    await enabler.wait()
    Log.d("task enabler #\(enabler.number) returning closure")
    return Task<Type,Error> {
        Log.d("task enabler #\(enabler.number) running closure")
        do {
            let ret = try await closure() // run closure in separate task
            Log.d("task enabler #\(enabler.number) about to decrement number running")
            await numberRunning.decrement()
            Log.d("task enabler #\(enabler.number) decremented number running")
            return ret
        } catch {
            Log.e("Task Error: \(error)")
            await numberRunning.decrement()
            Log.d("task enabler #\(enabler.number) decremented number running after error")
            throw error
        }
    }
}
