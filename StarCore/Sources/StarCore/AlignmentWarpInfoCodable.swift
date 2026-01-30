import Foundation

/// Swift-only, JSON-safe representation
public struct AlignmentWarpInfoCodable: Codable, Sendable {
    /// Row-major 3x3 homography (length = 9)
    public let homography: [Double]?

    // the same as calling homographyDeviation on the above homography
    public let deviation: Double

    // how this homography was discovered,
    // or what error caused it to not exist
    public let alignmentState: AlignmentState

    // frame index of the warped frame
    public let frameIndex: Int
}


// calculates how var the passed homography is from identity
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
