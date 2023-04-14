import Foundation

// an alternative to task groups, looking for thread stability

@available(macOS 10.15, *)
fileprivate var number_running = NumberRunning()

// XXX getting this number right is hard
// too big and the swift runtime barfs underneath
// too small and the process runs without available cpu resources
fileprivate let max_running: UInt = UInt(ProcessInfo.processInfo.activeProcessorCount)

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
@available(macOS 10.15, *)
public func runTask<Type>(_ closure: @escaping () async -> Type) async -> Task<Type,Never> {
    //Log.i("runtask with cpuUsage \(cpuUsage())")
    if await number_running.startOnIncrement(to: max_running) {
        return Task<Type,Never> {
            let ret = await closure() // run closure in separate task
            await number_running.decrement()
            return ret
        }
    } else {
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
@available(macOS 10.15, *)
public func runThrowingTask<Type>(_ closure: @escaping () async throws -> Type) async throws -> Task<Type,Error> {
    if await number_running.startOnIncrement(to: max_running) {
        return Task<Type,Error> {
            let ret = try await closure() // run closure in separate task
            await number_running.decrement()
            return ret
        }
    } else {
        let ret = try await closure()     // run closure in same task 
        return Task { ret }               // use task only to return value
    }
}
