import Foundation

/*

This file is part of the Starry Timelapse Airplane Remover (star).

star is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

star is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with star. If not, see <https://www.gnu.org/licenses/>.

*/

// a wrapper around runThrowingTask that keeps too many tasks from running at the same time

public actor LimitedThrowingTaskGroup<T> {

    var tasks: [Task<T,Error>] = []
    var iterator = 0
    
    let taskPriority: TaskPriority
    let idlePercentage: Double
    
    public init(at taskPriority: TaskPriority,
                idlePercentage: Double) // percentage of idle CPU needed before starting task
    {
        self.taskPriority = taskPriority
        self.idlePercentage = idlePercentage
    }

    public func next() async throws ->  T? {
        if iterator >= tasks.count { return nil }
        iterator += 1
        return try await tasks[iterator].value
    }

    public func forEach(_ closure: (T) -> Void) async throws {
        for task in tasks { closure(try await task.value) }
    }
    
    public func waitForAll() async throws {
        for task in tasks { _ = try await task.value }
    }
    
    public func addTask(closure: @escaping () async throws -> T) async throws {
        tasks.append(try await runThrowingTask(at: taskPriority,
                                               idlePercentage: idlePercentage,
                                               closure))
    }
}

public func withLimitedThrowingTaskGroup<ChildTaskResult, GroupResult>(
  of childTaskResultType: ChildTaskResult.Type,
  at taskPriority: TaskPriority = .high,
  idle idlePercentage: Double = 15,
  returning returnType: GroupResult.Type = GroupResult.self,
  body: (inout LimitedThrowingTaskGroup<ChildTaskResult>) async throws -> GroupResult
) async throws -> GroupResult where ChildTaskResult : Sendable
{
    var limitedTaskGroup: LimitedThrowingTaskGroup<ChildTaskResult> =
      LimitedThrowingTaskGroup(at: taskPriority, idlePercentage: idlePercentage)
    return try await body(&limitedTaskGroup)
}
