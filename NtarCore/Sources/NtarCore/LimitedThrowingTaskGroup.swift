import Foundation

/*

This file is part of the Nightime Timelapse Airplane Remover (ntar).

ntar is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

ntar is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with ntar. If not, see <https://www.gnu.org/licenses/>.

*/

// a wrapper around runThrowingTask that keeps too many tasks from running at the same time

@available(macOS 10.15, *)
public actor LimitedThrowingTaskGroup<T> {

    var tasks: [Task<T,Error>] = []
    var iterator = 0
    
    public init() { }

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
        tasks.append(try await runThrowingTask(closure))
    }
}

@available(macOS 10.15, *)
public func withLimitedThrowingTaskGroup<ChildTaskResult, GroupResult>(
  of childTaskResultType: ChildTaskResult.Type,
  limitedTo maxConcurrent: Int = ProcessInfo.processInfo.activeProcessorCount,
  returning returnType: GroupResult.Type = GroupResult.self,
  body: (inout LimitedThrowingTaskGroup<ChildTaskResult>) async throws -> GroupResult
) async throws -> GroupResult where ChildTaskResult : Sendable
{
    return try await withThrowingTaskGroup(of: ChildTaskResult.self, returning: returnType) { taskGroup in
        var limitedTaskGroup: LimitedThrowingTaskGroup<ChildTaskResult> = LimitedThrowingTaskGroup()
        return try await body(&limitedTaskGroup)
    }
}
