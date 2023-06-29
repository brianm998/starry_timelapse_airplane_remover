import Foundation

// this class is to debug issues with not calling DispatchHandler.leave() properly

public actor DispatchHandler {

    // these are helpful for debugging but are not async aware,
    // and making this class an actor causes too many other changes
    var count = 0
    var running: [String:Bool] = [:] // could be a set
    public let dispatchGroup = DispatchGroup()
    
    public init() { }
    
    func enter(_ name: String) -> Bool {
        //Log.d("enter \(name) with \(count)")
        count += 1
        if let _ = running[name] {
            Log.e("Error - more than one \(name) not allowed")
            return false
        }
        running[name] = true
        self.dispatchGroup.enter()
        return true
    }

    func leave(_ name: String) {
        //Log.d("leave \(name) with \(count)")
        count -= 1
        if running.removeValue(forKey: name) == nil { fatalError("\(name) was not entered, cannot leave") }
        self.dispatchGroup.leave()
    }
}
