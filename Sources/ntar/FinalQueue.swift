import Foundation
import Cocoa

// this class runs the queue of processes that finishes each frame
// it exists mainly to limit the concurrent number of processes running

@available(macOS 10.15, *)
actor FinalQueue {
    // actors
    let method_list = MethodList()       // a list of methods to process each frame
    let number_running = NumberRunning() // how many methods are running right now
    let max_concurrent: UInt
    var should_run = true

    let dispatch_group: DispatchGroup

    init(max_concurrent: UInt = 8, dispatchGroup dispatch_group: DispatchGroup) {
        self.max_concurrent = max_concurrent
        self.dispatch_group = dispatch_group
    }

    func finish() {
        should_run = false
    }

    func should_run() async -> Bool {
        let number_running = await self.number_running.currentValue()
        let count = await method_list.count
        //Log.d("should run \(should_run) && \(number_running) > 0")
        return should_run || number_running > 0 || count > 0
    }

    func removeValue(forKey key: Int) async {
        Log.d("removeValue(forKey: \(key))")
        await method_list.removeValue(forKey: key)
    }


    /*

     small size test runs still seem to be single threaded in this queue.

     longer running tasks seem find

     try using task groups to fix it?

    */
    nonisolated func start() async {
        self.dispatch_group.enter()
        Task { 
            while(await self.should_run()) {
                let current_running = await self.number_running.currentValue()
                Log.d("current_running \(current_running)")
                if(current_running < self.max_concurrent) {
                    let fu1 = await self.method_list.nextKey
                    if let next_key = fu1,
                       let method = await self.method_list.list[next_key]
                    {
                        self.dispatch_group.enter()
                        await self.method_list.removeValue(forKey: next_key)
                        await self.number_running.increment()
                        dispatchQueue.async {
                            Task {
                                await method()
                                await self.number_running.decrement()
                                self.dispatch_group.leave()
                            }
                        }
                    } else {
                        sleep(1)        // XXX hardcoded constant
                    }
                } else {
                    _ = self.dispatch_group.wait(timeout: DispatchTime.now().advanced(by: .seconds(1)))
                }
            }
            Log.d("done")
            self.dispatch_group.leave()
        }
    }
}

