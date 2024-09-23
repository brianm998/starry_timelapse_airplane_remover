import Foundation
import StarCore
import logging

// an older alternative to task groups, looking for thread stability
// still used by the decision tree generator

fileprivate let numberRunning = NumberRunning()

public class TaskRunnerOld {
    // XXX getting this number right is hard
    // too big and the swift runtime barfs underneath
    // too small and the process runs without available cpu resources
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
nonisolated(unsafe) public func runTaskOld<Type>(_ closure: @escaping @Sendable () async -> Type,
                                                 withCPUCount numCPUs: UInt = 1)
  async -> Task<Type,Never>
{
    //Log.i("runtask with cpuUsage \(cpuUsage())")
    let baseMax = TaskRunnerOld.maxConcurrentTasks
    let max = baseMax// > reserve ? baseMax - reserve : baseMax
//    if true {
    if await numberRunning.startOnIncrement(to: max) {
        //Log.v("running in new task")
        return Task<Type,Never> {
            let ret = await closure() // run closure in separate task
            //Log.v("new task done")
            await numberRunning.decrement()
            return ret
        }
    } else {
        //Log.v("running in existing task")
        let ret = await closure()     // run closure in same task 
        return Task { ret }           // use task only to return value
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
public func runThrowingTaskOld<Type>(_ closure: @escaping @Sendable () async throws -> Type,
                                     withCPUCount numCPUs: UInt = 1) async throws -> Task<Type,Error>
{
    let baseMax = TaskRunnerOld.maxConcurrentTasks
    let max = baseMax// > reserve ? baseMax - reserve : baseMax
//    if true {
    if await numberRunning.startOnIncrement(to: max) {
        //Log.v("running in new task")
        return Task<Type,Error> {
            let ret = try await closure() // run closure in separate task
            //Log.v("new task done")
            await numberRunning.decrement()
            return ret
        }
    } else {
        //Log.v("running in existing task")
        let ret = try await closure()     // run closure in same task 
        return Task { ret }               // use task only to return value
    }
}
