import Foundation

/*

This file is part of the Nightime Timelapse Airplane Remover (ntar).

ntar is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

ntar is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with ntar. If not, see <https://www.gnu.org/licenses/>.

*/

@available(macOS 10.15, *)
public class LimitedThrowingTaskGroup<T,E> where E : Error{
    var taskGroup: ThrowingTaskGroup<T,E>
    let maxConcurrent: Int
    let number_running: NumberRunning
    
    public init(taskGroup: ThrowingTaskGroup<T,E>, maxConcurrent: Int) {
        self.taskGroup = taskGroup
        self.maxConcurrent = maxConcurrent
        self.number_running = NumberRunning(in: "decision tree generator")
    }

    public func next() async throws ->  T? {
        return try await taskGroup.next()
    }

    public func waitForAll() async throws {
        try await taskGroup.waitForAll()
    }
    
    public func addTask(closure: @escaping () async throws -> T) async {

        var current_running = await number_running.currentValue()
        while current_running > maxConcurrent {
            //Log.d("waiting, \(current_running) are currently running")
            do {
                try await Task.sleep(nanoseconds: 500_000_000) // 500 ms
            } catch {
                Log.e("\(error)")
            }
            current_running = await number_running.currentValue()
            //Log.d("awaking \(current_running) are still running")
        }
        Log.d("starting another task with \(current_running)")
        await number_running.increment()
        
        taskGroup.addTask() {
            let ret = try await closure()
            await self.number_running.decrement()
            return ret
        }
    }
}

@available(macOS 10.15, *)
public func withLimitedThrowingTaskGroup<ChildTaskResult, GroupResult>(
  of childTaskResultType: ChildTaskResult.Type,
  limitedTo maxConcurrent: Int = 10,
  returning returnType: GroupResult.Type = GroupResult.self,
  body: (inout LimitedThrowingTaskGroup<ChildTaskResult, any Error>) async throws -> GroupResult
) async throws -> GroupResult where ChildTaskResult : Sendable
{
    return try await withThrowingTaskGroup(of: ChildTaskResult.self, returning: returnType) { taskGroup in
        var limitedTaskGroup = LimitedThrowingTaskGroup(taskGroup: taskGroup, maxConcurrent: maxConcurrent)
        return try await body(&limitedTaskGroup)
    }
}
