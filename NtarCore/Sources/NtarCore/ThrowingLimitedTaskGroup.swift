import Foundation

/*

This file is part of the Nightime Timelapse Airplane Remover (ntar).

ntar is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

ntar is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with ntar. If not, see <https://www.gnu.org/licenses/>.

*/

// a wrapper around the ThrowingTaskGroup that has keeps too many groups from
// running concurrently

@available(macOS 10.15, *)
public class ThrowingLimitedTaskGroup<T, Error> where Error: Swift.Error {
    var taskGroup: ThrowingTaskGroup<T, Error>
    let maxConcurrent: Int
    let number_running: NumberRunning
    
    public init(taskGroup: ThrowingTaskGroup<T, Error>, maxConcurrent: Int) {
        self.taskGroup = taskGroup
        self.maxConcurrent = maxConcurrent
        self.number_running = NumberRunning()
    }

    public func next() async throws ->  T? {
        return try await taskGroup.next()
    }

    public func waitForAll() async throws {
        try await taskGroup.waitForAll()
    }
    
    public func addTask(closure: @escaping () async throws -> T) async rethrows {

        var current_running = await number_running.currentValue()
        while current_running > maxConcurrent {
            do {
                try await Task.sleep(nanoseconds: 500_000_000) // 500 ms
            } catch {
                Log.e("\(error)")
            }
            current_running = await number_running.currentValue()
            //Log.d("awaking \(current_running) are still running")
        }
        await number_running.increment()
        
        taskGroup.addTask() {
            let ret = try await closure()
            await self.number_running.decrement()
            return ret
        }
    }
}


@available(macOS 10.15, *)
public func withThrowingLimitedTaskGroup<ChildTaskResult, GroupResult>(
  of childTaskResultType: ChildTaskResult.Type,
  limitedTo maxConcurrent: Int = ProcessInfo.processInfo.activeProcessorCount,
  returning returnType: GroupResult.Type = GroupResult.self,
  body: (inout ThrowingLimitedTaskGroup<ChildTaskResult, Error>) async throws -> GroupResult
) async rethrows -> GroupResult where ChildTaskResult : Sendable
{
    return try await withThrowingTaskGroup(of: ChildTaskResult.self, returning: returnType) { taskGroup in
        var limitedTaskGroup = ThrowingLimitedTaskGroup(taskGroup: taskGroup, maxConcurrent: maxConcurrent)
        return try await body(&limitedTaskGroup)
    }
}
