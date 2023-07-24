import Foundation

/*

This file is part of the Starry Timelapse Airplane Remover (star).

star is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

star is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with star. If not, see <https://www.gnu.org/licenses/>.

*/

// a wrapper around the ThrowingTaskGroup that has keeps too many tasks from
// running concurrently

public actor LimitedTaskGroup<T> {
    var tasks: [Task<T,Never>] = []
    var iterator = 0
    
    public init() { }

    public func next() async ->  T? {
        if iterator >= tasks.count { return nil }
        iterator += 1
        return await tasks[iterator].value
    }

    public func forEach(_ closure: (T) -> Void) async {
        for task in tasks { closure(await task.value) }
    }
    
    public func waitForAll() async {
        for task in tasks { _ = await task.value }
    }

    public func addTask(closure: @escaping () async -> T) async {
        // this may or may not run in the background, depending upon how
        // many other active Tasks are running
        tasks.append(await runTask(closure))
    }
}

/* 
func example() async {
    await withLimitedTaskGroup(of: Void.self) { taskGroup in
        for i in (0..<200) {
            await taskGroup.addTask() {
                doSomething()
            }
        }
        await taskGroup.waitForAll()
    }
}
 */


public func withLimitedTaskGroup<ChildTaskResult, GroupResult>(
  of childTaskResultType: ChildTaskResult.Type,
  limitedTo maxConcurrent: Int = ProcessInfo.processInfo.activeProcessorCount,
  returning returnType: GroupResult.Type = GroupResult.self,
  body: (inout LimitedTaskGroup<ChildTaskResult>) async -> GroupResult
) async -> GroupResult where ChildTaskResult : Sendable
{
    var limitedTaskGroup: LimitedTaskGroup<ChildTaskResult> = LimitedTaskGroup()
    return await body(&limitedTaskGroup)
}
