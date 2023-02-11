import Foundation

// this class is to debug issues with not calling DispatchHandler.leave() properly

@available(macOS 10.15, *)
public actor DispatchHandler {

    // these are helpful for debugging but are not async aware,
    // and making this class an actor causes too many other changes
    var count = 0
    var running: [String:Bool] = [:] // could be a set
    public let dispatch_group = DispatchGroup()
    
    public init() { }
    
    func enter(_ name: String) {
        //Log.d("enter \(name) with \(count)")
        count += 1
        if let _ = running[name] { fatalError("more than one \(name) not allowed") }
        running[name] = true
        self.dispatch_group.enter()
    }

    func leave(_ name: String) {
        //Log.d("leave \(name) with \(count)")
        count -= 1
        if running.removeValue(forKey: name) == nil { fatalError("\(name) was not entered, cannot leave") }
        self.dispatch_group.leave()
    }
}
