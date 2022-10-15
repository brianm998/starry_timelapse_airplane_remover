import Foundation

public class Outlier: Hashable, Equatable {
    let x: UInt16
    let y: UInt16
    let amount: Int32

    var tag: String?
    var done: Bool = false
    
    var left: Outlier?
    var right: Outlier?
    var top: Outlier?
    var bottom: Outlier?
    
    public init(x: UInt16, y: UInt16, amount: Int32) {
        self.x = x
        self.y = y
        self.amount = amount
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(x)
        hasher.combine(y)
    }

    public static func == (lhs: Outlier, rhs: Outlier) -> Bool {
        return
            lhs.x == rhs.x &&
            lhs.y == rhs.y
    }    

    var taglessUndoneNeighbors: [Outlier] {
        return self.directNeighbors.filter { neighbor in
            return neighbor.tag == nil && !neighbor.done
        }
    }
    var directNeighbors: [Outlier] {
        get {
            var ret: [Outlier] = []
            if let left   = self.left   {ret.append(left)}
            if let right  = self.right  {ret.append(right)}
            if let top    = self.top    {ret.append(top)}
            if let bottom = self.bottom {ret.append(bottom)}
            return ret
        }
    }
}

