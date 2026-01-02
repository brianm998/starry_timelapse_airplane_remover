import Foundation

/// Swift-only, JSON-safe representation
public struct AlignmentWarpInfoCodable: Codable, Sendable {
    /// Row-major 3x3 homography (length = 9)
    public let homography: [Double]?

    public let deviation: Double
    public let maxCornerDeviation: Double
    public let alignmentState: AlignmentState
    public let neighborKeyPoints: Int
    public let frameKeyPoints: Int
    public let frameIndex: Int
}

