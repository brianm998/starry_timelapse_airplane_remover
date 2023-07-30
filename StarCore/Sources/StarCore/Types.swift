import Foundation

// these values are used for creating an initial config when processing a new sequence
public struct Defaults {

    /*
     The outlier max and min thresholds below are percentages of how much a
     pixel is brighter than the same pixel in adjecent frames.

     If a pixel is outlierMinThreshold percentage brighter, then it is an outlier.
     If a pixel is brighter than outlierMaxThreshold, then it is painted over fully.
     If a pixel is between these two values, then an alpha between 0-1 is applied.

     A lower outlierMaxThreshold results in detecting more outlier groups.
     A higher outlierMaxThreshold results in detecting fewer outlier groups.
     */
    public static let outlierMaxThreshold: Double = 5
    public static let outlierMinThreshold: Double = 2.5

    // groups smaller than this are completely ignored
    public static let minGroupSize: Int = 20
}

// make any string into an Error, so it can be thrown by itself if desired
extension String: Error {}

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


