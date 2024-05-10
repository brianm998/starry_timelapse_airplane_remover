import Foundation
import logging

// an alternative to task groups, looking for thread stability

public let defaultTaskMaster = TaskMaster(maxConcurrentTasks: TaskRunner.maxConcurrentTasks)

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
                          with taskMaster: TaskMaster = defaultTaskMaster,
                          _ closure: @escaping () async -> Type) async -> Task<Type,Never>
{
    let enabler = TaskEnabler(priority: priority)
    await taskMaster.register(enabler)
    await enabler.wait()
    return Task<Type,Never> {
        let ret = await closure() // run closure in separate task
        await taskMaster.numberRunning.decrement()
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
public func runThrowingTask<Type>(at priority: TaskPriority = .medium,
                                  with taskMaster: TaskMaster = defaultTaskMaster,
                                  _ closure: @escaping () async throws -> Type)
  async throws -> Task<Type,Error>
{
    let enabler = TaskEnabler(priority: priority)
    await taskMaster.register(enabler)
    await enabler.wait()
    return Task<Type,Error> {
        do {
            let ret = try await closure() // run closure in separate task
            await taskMaster.numberRunning.decrement()
            return ret
        } catch {
            await taskMaster.numberRunning.decrement()
            throw error
        }
    }
}


public func runDeferredThrowingTask<Type>(at priority: TaskPriority = .medium,
                                          with taskMaster: TaskMaster = defaultTaskMaster,
                                          _ closure: @escaping () async throws -> Type)
  async throws -> Task<Type,Error>
{
    return Task<Type,Error> {
        let enabler = TaskEnabler(priority: priority)
        await taskMaster.register(enabler)
        await enabler.wait()
        do {
            let ret = try await closure() // run closure in separate task
            await taskMaster.numberRunning.decrement()
            return ret
        } catch {
            await taskMaster.numberRunning.decrement()
            throw error
        }
    }
}
