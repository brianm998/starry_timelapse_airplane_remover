import Foundation

extension String: Error {}

// these values are used for creating an initial config when processing a new sequence
public struct Defaults {
    public static let outlierMaxThreshold: Double = 13 // XXX document these
    public static let outlierMinThreshold: Double = 9
    public static let minGroupSize: Int = 80      // groups smaller than this are completely ignored
}

// x, y coordinates
public struct Coord: Codable {
    public let x: Int
    public let y: Int

    public init(x: Int, y: Int) {
        self.x = x
        self.y = y
    }
}

// polar coordinates for right angle intersection with line from origin
public struct Line: Codable {
    public let theta: Double                 // angle in degrees
    public let rho: Double                   // distance in pixels
    public let count: Int                    // higher count is better fit for line
}

public enum Edge {
    case vertical
    case horizontal
}

// a member in an airplane streak across frames
typealias AirplaneStreakMember = (
  frame_index: Int,
  group: OutlierGroup,
  distance: Double?      // the distance from this member to the previous one, nil if first member
)

