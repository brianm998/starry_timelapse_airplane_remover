import Foundation

/*

This file is part of the Starry Timelapse Airplane Remover (star).

star is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

star is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with star. If not, see <https://www.gnu.org/licenses/>.

*/

// a wrapper around the ThrowingTaskGroup that has keeps too many groups from
// running concurrently

public class ThrowingLimitedTaskGroup<T, Error> where Error: Swift.Error {
    var taskGroup: ThrowingTaskGroup<T, Error>
    let maxConcurrent: Int
    let numberRunning: NumberRunning
    
    public init(taskGroup: ThrowingTaskGroup<T, Error>, maxConcurrent: Int) {
        self.taskGroup = taskGroup
        self.maxConcurrent = maxConcurrent
        self.numberRunning = NumberRunning()
    }

    public func next() async throws ->  T? {
        return try await taskGroup.next()
    }

    public func waitForAll() async throws {
        try await taskGroup.waitForAll()
    }
    
    public func addTask(closure: @escaping () async throws -> T) async rethrows {

        var current_running = await numberRunning.currentValue()
        while current_running > maxConcurrent {
            do {
                try await Task.sleep(nanoseconds: 500_000_000) // 500 ms
            } catch {
                Log.e("\(error)")
            }
            current_running = await numberRunning.currentValue()
            //Log.d("awaking \(current_running) are still running")
        }
        await numberRunning.increment()
        
        taskGroup.addTask() {
            let ret = try await closure()
            await self.numberRunning.decrement()
            return ret
        }
    }
}


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
