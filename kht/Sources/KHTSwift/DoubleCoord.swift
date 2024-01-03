import Foundation

// x, y coordinates as doubles
public struct DoubleCoord: Codable, CustomStringConvertible {
    public let x: Double
    public let y: Double

    public var description: String {
        let xStr = String(format: "%2f", x)
        let yStr = String(format: "%2f", y)
        return "DoubleCoord [\(xStr), \(yStr)]"
    }
    
    public init(_ coord: Coord) {
        self.x = Double(coord.x)
        self.y = Double(coord.y)
    }
    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public func distance(to other: DoubleCoord) -> Double {
        let x_diff = self.x - other.x
        let y_diff = self.y - other.y
        return sqrt(x_diff*x_diff+y_diff*y_diff)
    }
    
    public var hasNaN: Bool { x.isNaN || y.isNaN }
    public var isFinite: Bool { x.isFinite && y.isFinite }
    public var isRational: Bool { !self.hasNaN && self.isFinite }
    
    public func standardLine(with otherPoint: DoubleCoord) -> StandardLine {
        let dx1 = self.x
        let dy1 = self.y
        let dx2 = otherPoint.x
        let dy2 = otherPoint.y

        let x_diff = dx1-dx2
        let y_diff = dy1-dy2

        if x_diff == 0 {
            // vertical line
            // x = c
            // 1*x + 0*y - c = 0
            
            return StandardLine(a: 1, b: 0, c: -dx1)
        } else if y_diff == 0 {
            // horizontal line
            // y = c
            // 0*x + 1*y - c = 0
            
            return StandardLine(a: 0, b: 1, c: -dy1)
        } else {
        
            let slope = y_diff / x_diff

            // y - dy2 = slope*(x - dx2)
            // y/slope - dy2/slope = x - dx2
            // -1*x + 1/slope * y = dy2/slope - dx2
            // -1*x + 1/slope * y - (dy2/slope - dx2) = 0

            let a = -1.0
            let b = 1/slope
            let c = -(dy2/slope - dx2)

            return StandardLine(a: a, b: b, c: c)
        }
    }
}
