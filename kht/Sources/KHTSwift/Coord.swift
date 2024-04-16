import Foundation

// x, y coordinates
public struct Coord: Codable, Equatable {
    public let x: Int
    public let y: Int

    public init(x: Int, y: Int) {
        self.x = x
        self.y = y
    }

    public init(_ coord: DoubleCoord) {
        self.x = Int(coord.x)
        self.y = Int(coord.y)
    }

    public static func == (lhs: Coord, rhs: Coord) -> Bool {
        lhs.x == rhs.x && lhs.y == rhs.y 
    }
    
    public func distance(from other: Coord) -> Double {
        let x_diff = Double(x - other.x)
        let y_diff = Double(y - other.y)
        return sqrt(x_diff*x_diff + y_diff*y_diff)
    }
}
