import Foundation
import logging


fileprivate let processorUsage = ProcessorUsageTracker()
fileprivate let prioritizer = Prioritizer()

// XXX next keep track of how many are running, and cap it at some number
// there is a failure mode where we can still crash if the machine is thrashing,
// cpu usage can be low, but adding more tasks doesn't increase it, just digs deeper

// an alternative to task groups, looking for thread stability

public func runTask<Type>(at taskPriority: TaskPriority,
                          idlePercentage: Double = 20,
                          _ closure: @escaping () async -> Type) async -> Task<Type,Never>
{
    await prioritizer.registerToRun(at: taskPriority)

    let sleeptime = nanosecondsOfSleep(for: taskPriority)
    
    while !(await canRun(at: taskPriority, with: idlePercentage)) {
        do { try await Task.sleep(nanoseconds: sleeptime) } catch { }
    }
    await processorUsage.reset()
    await prioritizer.registerRunning(at: taskPriority)
    
    return Task<Type,Never>(priority: taskPriority) { await closure() }
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
public func runThrowingTask<Type>(at taskPriority: TaskPriority,
                                  idlePercentage: Double = 20,
                                  _ closure: @escaping () async throws -> Type) async throws -> Task<Type,Error>
{
    await prioritizer.registerToRun(at: taskPriority)

    let sleeptime = nanosecondsOfSleep(for: taskPriority)
    
    while !(await canRun(at: taskPriority, with: idlePercentage)) {
        do { try await Task.sleep(nanoseconds: sleeptime) } catch { }
    }
    await processorUsage.reset()
    await prioritizer.registerRunning(at: taskPriority)

    return Task<Type,Error>(priority: taskPriority) { try await closure() }
}

fileprivate func canRun(at taskPriority: TaskPriority, with idlePercentage: Double) async -> Bool {
    if await prioritizer.canRun(at: taskPriority) {
        if await processorUsage.isIdle(byAtLeast: idlePercentage) {
            return true
        }
    }
    return false
}

// make sure higher priority jobs run first
fileprivate actor Prioritizer {

    init () { } 
    
    var background: Int = 0
    var utility: Int = 0
    var low: Int = 0
    var medium: Int = 0
    var high: Int = 0
    var userInitiated: Int = 0

    func canRun(at taskPriority: TaskPriority) -> Bool {

        var ret = true
        if taskPriority == .userInitiated {
            ret = true
        } else if taskPriority == .high {
            ret = userInitiated == 0
        } else if taskPriority == .medium {
            ret = high == 0 && userInitiated == 0
        } else if taskPriority == .low {
            ret = medium == 0 && high == 0 && userInitiated == 0
        } else if taskPriority == .utility {
            ret = low == 0 && medium == 0 && high == 0 && userInitiated == 0
        } else if taskPriority == .background {
            ret = utility == 0 && low == 0 && medium == 0 && high == 0 && userInitiated == 0
        } else {
            Log.e("unhandled task priority \(taskPriority)")
            ret = false
        }

        //Log.d("canRun(at: \(taskPriority): \(ret) - background \(background) utility \(utility) low \(low) medium \(medium) high \(high) userInitiated \(userInitiated)")
        
        return ret
    }

    // increment counters per priority
    func registerToRun(at taskPriority: TaskPriority) {
        if taskPriority == .userInitiated {
            userInitiated += 1
        } else if taskPriority == .high {
            high += 1
        } else if taskPriority == .medium {
            medium += 1
        } else if taskPriority == .low {
            low += 1
        } else if taskPriority == .utility {
            utility += 1
        } else if taskPriority == .background {
            background += 1
        }
    }

    // decrement counters per priority
    func registerRunning(at taskPriority: TaskPriority) {
        if taskPriority == .userInitiated {
            userInitiated -= 1
            if userInitiated < 0 { userInitiated = 0 }
        } else if taskPriority == .high {
            high -= 1
            if high < 0 { high = 0 }
        } else if taskPriority == .medium {
            medium -= 1
            if medium < 0 { medium = 0 }
        } else if taskPriority == .low {
            low -= 1
            if low < 0 { low = 0 }
        } else if taskPriority == .utility {
            utility -= 1
            if utility < 0 { utility = 0 }
        } else if taskPriority == .background {
            background -= 1
            if background < 0 { background = 0 }
        }
    }
}

fileprivate func nanosecondsOfSleep(for taskPriority: TaskPriority) -> UInt64 {
    if taskPriority == .userInitiated {
        return 100_000_000
    } else if taskPriority == .high {
        return 200_000_000
    } else if taskPriority == .medium {
        return 400_000_000
    } else if taskPriority == .low {
        return 600_000_000
    } else if taskPriority == .utility {
        return 800_000_000
    } else if taskPriority == .background {
        return 1_000_000_000
    } else {
        return 2_000_000_000
    }
}
