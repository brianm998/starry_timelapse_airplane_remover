import Foundation
import CoreGraphics

public extension Double {
    var int: Int? {
        if self >= Double(Int.min) && self < Double(Int.max) {
            return Int(self)
        } else {
            return nil
        }
    }
}

public extension CGFloat {
    var int: Int? {
        if self >= CGFloat(Int.min) && self < CGFloat(Int.max) {
            return Int(self)
        } else {
            return nil
        }
    }
}
