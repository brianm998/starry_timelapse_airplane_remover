import Foundation
import logging
import Semaphore

// an alternative to task groups, looking for thread stability

fileprivate var numberRunning = NumberRunning()

public let taskMaster = TaskMaster()

public class TaskRunner {
    // XXX getting this number right is hard
    // too big and the swift runtime barfs underneath
    // too small and the process runs without available cpu resources
    public static var maxConcurrentTasks: UInt = determineMax() {
        didSet {
            Log.i("using maximum of \(maxConcurrentTasks) concurrent tasks")
        }
    }
}

fileprivate func determineMax() -> UInt {
    var numProcessors = ProcessInfo.processInfo.activeProcessorCount
    numProcessors -= numProcessors/4
    if numProcessors < 2 { numProcessors = 2 }
    return UInt(numProcessors)
}

public class TaskEnabler {
    public let priority: TaskPriority
    private let semaphore = AsyncSemaphore(value: 0)
    
    public init(priority: TaskPriority) {
        self.priority = priority
    }

    public func wait() async { await semaphore.wait() }
    
    public func enable() { semaphore.signal() }

}

public actor TaskMaster {

    private var highPrioTasks: [TaskEnabler] = []
    private var mediumPrioTasks: [TaskEnabler] = []
    private var lowPrioTasks: [TaskEnabler] = []

    public func register(_ enabler: TaskEnabler) async {
        if await numberRunning.startOnIncrement(to: TaskRunner.maxConcurrentTasks) {
            // let it run right now
            enabler.enable()
        } else {
            // register to run it later
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
            // we can start another task, look for one
            if highPrioTasks.count > 0 {
                highPrioTasks.removeFirst().enable()
            } else if mediumPrioTasks.count > 0 {
                mediumPrioTasks.removeFirst().enable()
            } else if lowPrioTasks.count > 0 {
                lowPrioTasks.removeFirst().enable()
            } else {
                // no tasks found to run,
                // decrement number running after increment above
                await numberRunning.decrement()
            }
        }
    }
}

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
    let enabler = TaskEnabler(priority: priority)
    await taskMaster.register(enabler)
    await enabler.wait()
    return Task<Type,Never> {
        let ret = await closure() // run closure in separate task
        await numberRunning.decrement()
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
    let enabler = TaskEnabler(priority: priority)
    await taskMaster.register(enabler)
    await enabler.wait()
    return Task<Type,Error> {
        do {
            let ret = try await closure() // run closure in separate task
            await numberRunning.decrement()
            return ret
        } catch {
            await numberRunning.decrement()
            throw error
        }
    }
}
