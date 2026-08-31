import Foundation
import logging

// an alternative to task groups, looking for thread stability

public let defaultTaskMaster = TaskMaster(maxConcurrentTasks: TaskRunner.maxConcurrentTasks)

public class TaskRunner {
    // How many frame-level tasks run at once.
    //
    // The "too big and the swift runtime barfs underneath" this used to warn
    // about was the cooperative thread pool starving: every concurrent frame
    // held one of its (core-count many) threads blocked inside OpenCV, so
    // going wide left the runtime with nothing to schedule its own async work
    // on.  Backing off to three quarters of the cores kept enough free that it
    // limped along.
    //
    // `NativeWork` moved that blocking work off the pool, so the runtime is no
    // longer the constraint and this is free to be a throughput decision again.
    // It is left where it was deliberately: raising it also raises peak memory
    // and how far OpenCV fans out underneath (it picks the GCD backend and
    // ignores cv::setNumThreads above 1, so each concurrent op brings its own
    // workers — see medianMergeTyped in ImageAligner.cpp).  That wants a
    // measured run, not a guess, and end-to-end runs on this hardware vary by
    // ~90s on identical settings.
    //
    // Note `NativeWork.concurrencyLimit` reads this, so it still bounds the
    // native work too — just without holding cooperative threads to do it.
    nonisolated(unsafe) public static var maxConcurrentTasks: UInt = determineMax() {
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
                          _ closure: @escaping @Sendable () async -> Type) async -> Task<Type,Never>
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
                                  _ closure: @escaping @Sendable () async throws -> Type)
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
                                          _ closure: @escaping @Sendable () async throws -> Type)
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
