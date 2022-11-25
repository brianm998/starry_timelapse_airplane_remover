import Foundation
import Cocoa

/*

This file is part of the Nightime Timelapse Airplane Remover (ntar).

ntar is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

ntar is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with ntar. If not, see <https://www.gnu.org/licenses/>.

*/

// this class runs the queue of processes that finishes each frame
// it exists mainly to limit the concurrent number of processes running

@available(macOS 10.15, *)
actor FinalQueue {
    // actors
    let method_list = MethodList<Void>()       // a list of methods to process each frame
    let number_running = NumberRunning() // how many methods are running right now
    let max_concurrent: UInt
    var should_run = true

    let dispatch_group: DispatchHandler

    init(max_concurrent: UInt = 8, dispatchGroup dispatch_group: DispatchHandler) {
        self.max_concurrent = max_concurrent
        self.dispatch_group = dispatch_group
    }

    func finish() {
        should_run = false
    }

    func should_run() async -> Bool {
        let number_running = await self.number_running.currentValue()
        let count = await method_list.count
        //Log.d("should run \(should_run) && \(number_running) > 0  count \(count)")
        return should_run || number_running > 0 || count > 0
    }

    func add(atIndex index: Int, method: @escaping () async throws -> Void) async {
        await method_list.add(atIndex: index, method: method)
    }
    
    func removeValue(forKey key: Int) async {
        Log.d("removeValue(forKey: \(key))")
        await method_list.removeValue(forKey: key)
    }

    func value(forKey key: Int) async -> (() async throws -> ())? {
        return await method_list.value(forKey: key)
    }
    
    nonisolated func start() async throws {
        let name = "final queue running"
        await self.dispatch_group.enter(name)
        Log.d("starting")
        try await withThrowingTaskGroup(of: Void.self) { group in
            while(await self.should_run()) {
                let current_running = await self.number_running.currentValue()
                //Log.d("current_running \(current_running)")
                if(current_running < self.max_concurrent) {
                    let fu1 = await self.method_list.nextKey
                    if let next_key = fu1,
                       let method = await self.value(forKey: next_key)
                    {
                        let dispatch_name = "final queue frame \(next_key)"
                        await self.dispatch_group.enter(dispatch_name)
                        await self.removeValue(forKey: next_key)
                        await self.number_running.increment()
                        group.addTask {
                            try await method()
                            await self.number_running.decrement()
                            await self.dispatch_group.leave(dispatch_name)
                        }
                    } 
                } else {
                    // wait for the next to finish so we can start more
                    try await group.next()
                }
            }
            try await group.waitForAll()

            Log.d("done")
            await self.dispatch_group.leave(name)
        }
    }
}

