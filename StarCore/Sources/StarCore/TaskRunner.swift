import Foundation
import logging

// an alternative to task groups, looking for thread stability

fileprivate var numberRunning = NumberRunning()

public actor TaskRunner {
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
//    numProcessors -= numProcessors/4
//    if numProcessors < 2 { numProcessors = 2 }
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
public func runTask<Type>(_ closure: @escaping () async -> Type,
                       withCPUCount numCPUs: UInt = 1) async -> Task<Type,Never>
{
    //Log.i("runtask with cpuUsage \(cpuUsage())")
    let baseMax = TaskRunner.maxConcurrentTasks
    let max = baseMax// > reserve ? baseMax - reserve : baseMax

    while !(await numberRunning.startOnIncrement(to: max)) {
        do {
            try await Task.sleep(nanoseconds: 1_000_000_000)
        } catch { }
    }
    return Task<Type,Never> {
        let ret = await closure() // run closure in separate task
        //Log.v("new task done")
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
public func runThrowingTask<Type>(_ closure: @escaping () async throws -> Type,
                              withCPUCount numCPUs: UInt = 1) async throws -> Task<Type,Error>
{
    let baseMax = TaskRunner.maxConcurrentTasks
    let max = baseMax// > reserve ? baseMax - reserve : baseMax

    while !(await numberRunning.startOnIncrement(to: max)) {
        do {
            try await Task.sleep(nanoseconds: 1_000_000_000)
        } catch { }
    }
    
    //Log.v("running in new task")
    return Task<Type,Error> {
        let ret = try await closure() // run closure in separate task
        //Log.v("new task done")
        await numberRunning.decrement()
        return ret
    }
}
