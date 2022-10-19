import Foundation

public class Outlier: Hashable, Equatable, CustomStringConvertible {
    let x: Int
    let y: Int
    let amount: Int32

    var tag: String?            // XXX rename to groupName ?
    
    var left: Outlier?
    var right: Outlier?
    var top: Outlier?
    var bottom: Outlier?
    
    public init(x: Int, y: Int, amount: Int32) {
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

    var taglessNeighbors: [Outlier] {
        get {
            var ret: [Outlier] = []
            if let left   = self.left,   left.tag   == nil {ret.append(left)}
            if let right  = self.right,  right.tag  == nil {ret.append(right)}
            if let top    = self.top,    top.tag    == nil {ret.append(top)}
            if let bottom = self.bottom, bottom.tag == nil {ret.append(bottom)}
            return ret
        }
    }

    public var description: String {
        get {
            return "\(x),\(y)"
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

