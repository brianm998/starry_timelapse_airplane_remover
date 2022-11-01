import Foundation

// this class is to debug issues with not calling DispatchHandler.leave() properly

@available(macOS 10.15, *)
class DispatchHandlerTest: DispatchHandler {

    // these are helpful for debugging but are not async aware,
    // and making this class an actor causes too many other changes
    //var count = 0
    //var running: [String:Bool] = [:] // could be a set
    let dispatch_group = DispatchGroup()

    
    init() { }
    
    func enter(_ name: String) {
        //Log.d("enter \(name) with \(count)")
        //count += 1
        //if let _ = running[name] { fatalError("more than one \(name) not allowed") }
        //running[name] = true
        self.dispatch_group.enter()
    }

    func leave(_ name: String) {
        //Log.d("leave \(name) with \(count)")
        //count -= 1
        //if running.removeValue(forKey: name) == nil { fatalError("\(name) was not entered, cannot leave") }
        self.dispatch_group.leave()
    }

    func wait() {
        while (self.dispatch_group.wait(timeout: DispatchTime.now().advanced(by: .seconds(3))) == .timedOut) {
            Log.d("still waiting")
//            Log.d("we still \(count) left")
//            if count < 8 {      // XXX hardcoded constant
//                for (name, _) in running {
//                    Log.d("waiting on \(name)")
//                }
//            }
        }
        Log.d("wait done")
    }
}

//extension DispatchGroup: DispatchHandler { }

protocol DispatchHandler {
    func enter(_ name: String)
    func leave(_ name: String)
    func wait()
}
