import Foundation

extension String: Error {}

// x, y coordinates
public struct Coord: Codable {
    public let x: Int
    public let y: Int
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
@available(macOS 10.15, *) 
typealias AirplaneStreakMember = (
  frame_index: Int,
  group: OutlierGroup,
  distance: Double?      // the distance from this member to the previous one, nil if first member
)


