import Foundation

// x, y coordinates
public struct Coord: Codable {
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
}
