import Foundation
import logging

// an alternative to task groups, looking for thread stability

fileprivate let processorUsage = ProcessorUsage()

// how idle does the system have to be to start another task?
fileprivate let idlePercentage = 20.0

public func runTask<Type>(_ closure: @escaping () async -> Type) async -> Task<Type,Never>
{
    while !(await processorUsage.isIdle(byAtLeast: idlePercentage)) {
        do {
            try await Task.sleep(nanoseconds: 1_000_000_000)
        } catch { }
    }
    return Task<Type,Never> { await closure() }
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
public func runThrowingTask<Type>(_ closure: @escaping () async throws -> Type) async throws -> Task<Type,Error>
{
    while !(await processorUsage.isIdle(byAtLeast: idlePercentage)) {
        do {
            try await Task.sleep(nanoseconds: 1_000_000_000)
        } catch { }
    }
    return Task<Type,Error> { try await closure() }
}
