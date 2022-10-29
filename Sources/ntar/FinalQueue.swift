import Foundation
import Cocoa

@available(macOS 10.15, *)
actor FinalQueue {
    // actors
    let method_list = MethodList()       // a list of methods to process each frame
    let number_running = NumberRunning() // how many methods are running right now
    let max_concurrent: UInt
    var should_run = true
    
    // concurrent dispatch queue so we can process frames in parallel
    let dispatchQueue = DispatchQueue(label: "image_sequence_final_processor",
                                  qos: .unspecified,
                                  attributes: [.concurrent],
                                  autoreleaseFrequency: .inherit,
                                  target: nil)

    init(max_concurrent: UInt = 8) {
        self.max_concurrent = max_concurrent
    }

    func stop() {
        should_run = false
    }
    
    func add(atIndex index: Int, method: @escaping () async -> Void) async {
        await method_list.add(atIndex: index, method: method)
    }

    func removeValue(forKey key: Int) async {
        await method_list.removeValue(forKey: key)
    }

    nonisolated func start() async {
        self.dispatchQueue.async {
            Task { 
                while(await self.should_run) {
                    if let next_key = await self.method_list.nextKey,
                       let method = await self.method_list.list[next_key]
                    {
                        await method()
                        await self.method_list.removeValue(forKey: next_key)
                    } else {
                        sleep(1)        // XXX hardcoded constant
                    }
                }
            }
        }
    }
}

