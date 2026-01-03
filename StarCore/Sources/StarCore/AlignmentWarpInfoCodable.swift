import Foundation

/// Swift-only, JSON-safe representation
public struct AlignmentWarpInfoCodable: Codable, Sendable {
    /// Row-major 3x3 homography (length = 9)
    public let homography: [Double]?

    public let deviation: Double
    public let alignmentState: AlignmentState
    public let neighborKeyPoints: Int
    public let frameKeyPoints: Int
    public let frameIndex: Int

}



public func homographyDeviation(_ h: [Double]) -> Double {
    // Frobenius norm of (H - I)
    let I: [Double] = [
      1, 0, 0,
      0, 1, 0,
      0, 0, 1
    ]

    return zip(h, I)
      .map { ($0 - $1) * ($0 - $1) }
      .reduce(0, +)
      .squareRoot()
}
