import XCTest
import StarCppBridge
@testable import StarCore

/// `OutlierGroup.originZeroLine` is where a `polarCoords` sign error actually reached production:
/// it takes a blob's line, fitted in bounds-relative space, offsets `twoPoints` by `bounds.min`
/// to get back into absolute frame coordinates, and hands the pair to `Line(point1:point2:)`.
/// The resulting line is then measured against the group's own pixels by
/// `averageMedianMaxDistance` to produce the `averageLineVariance` and `medianLineVariance`
/// decision-tree features.
///
/// `polarCoords` used to mirror a line through the origin whenever its closest approach landed
/// in the negative quadrant, which `twoPoints + bounds.min` can easily produce for a blob near
/// the top-left of the frame.  A mirrored line sits nowhere near the pixels it was fitted to, so
/// those two features came out as large as if the fit had failed.  Measured over a sweep of
/// plausible blob geometries, 357 of 5160 (~7%) were affected, by up to 400 pixels.
final class OriginZeroLineTests: XCTestCase {

    private func group(boundsMin: Coord, boundsMax: Coord) -> OutlierGroup {
        OutlierGroup(id: 1, size: 1, brightness: 1000,
                     bounds: BoundingBox(min: boundsMin, max: boundsMax),
                     frameIndex: 0,
                     imageWidth: 1000, imageHeight: 500,
                     pixels: [], pixelSet: [])
    }

    /// The invariant: whatever line goes in, the absolute-coordinate line that comes out still
    /// passes through the same two points.
    func testTheOffsetLineStillPassesThroughItsOwnPoints() async {
        let outlier = group(boundsMin: Coord(x: 3, y: 3), boundsMax: Coord(x: 60, y: 60))

        for theta in stride(from: 5.0, to: 360.0, by: 5.0) {
            for rho in [3.0, 20.0, 200.0] {
                let fitted = Line(theta: theta, rho: rho)
                let (a, b) = fitted.twoPoints
                let p1 = DoubleCoord(x: a.x + 3, y: a.y + 3)
                let p2 = DoubleCoord(x: b.x + 3, y: b.y + 3)
                guard p1.x != p2.x, p1.y != p2.y else { continue }

                let absolute = await outlier.originZeroLine(from: fitted)
                guard absolute.rho > 0 else { continue }

                let rebuilt = absolute.standardLine
                XCTAssertEqual(rebuilt.distanceTo(p1), 0, accuracy: 1e-6,
                               "theta \(theta) rho \(rho): the offset line lost \(p1)")
                XCTAssertEqual(rebuilt.distanceTo(p2), 0, accuracy: 1e-6,
                               "theta \(theta) rho \(rho): the offset line lost \(p2)")
            }
        }
    }

    /// The same sweep across a range of bounds offsets, including a blob flush against the
    /// top-left corner where the negative-quadrant case is easiest to reach.
    func testTheOffsetLineHoldsForBlobsAnywhereInTheFrame() async {
        for (minX, minY) in [(0, 0), (3, 3), (40, 400), (1900, 1000)] {
            let outlier = group(boundsMin: Coord(x: minX, y: minY),
                                boundsMax: Coord(x: minX + 60, y: minY + 60))
            for theta in stride(from: 10.0, to: 360.0, by: 10.0) {
                let fitted = Line(theta: theta, rho: 20)
                let (a, b) = fitted.twoPoints
                let p1 = DoubleCoord(x: a.x + Double(minX), y: a.y + Double(minY))
                let p2 = DoubleCoord(x: b.x + Double(minX), y: b.y + Double(minY))
                guard p1.x != p2.x, p1.y != p2.y else { continue }

                let absolute = await outlier.originZeroLine(from: fitted)
                guard absolute.rho > 0 else { continue }

                let rebuilt = absolute.standardLine
                XCTAssertEqual(rebuilt.distanceTo(p1), 0, accuracy: 1e-6,
                               "bounds [\(minX), \(minY)] theta \(theta) mirrored the line")
                XCTAssertEqual(rebuilt.distanceTo(p2), 0, accuracy: 1e-6,
                               "bounds [\(minX), \(minY)] theta \(theta) mirrored the line")
            }
        }
    }

    /// The consequence the features actually see: the fitted line must sit close to the pixels
    /// it was fitted to.  A mirrored line lands on the far side of the origin instead, which is
    /// what inflated `averageLineVariance` / `medianLineVariance` for the affected groups.
    func testTheOffsetLineStaysNearThePixelsItWasFittedTo() async {
        // a blob near the top-left running diagonally, the shape most exposed to the old bug
        let boundsMin = Coord(x: 3, y: 3), boundsMax = Coord(x: 63, y: 63)
        let outlier = group(boundsMin: boundsMin, boundsMax: boundsMax)

        for theta in stride(from: 5.0, to: 360.0, by: 5.0) {
            let fitted = Line(theta: theta, rho: 20)
            let absolute = await outlier.originZeroLine(from: fitted)
            guard absolute.rho > 0 else { continue }

            // sample the fitted line inside the blob's own box, in absolute coordinates
            let (a, b) = fitted.twoPoints
            let sample = DoubleCoord(x: (a.x + b.x)/2 + Double(boundsMin.x),
                                     y: (a.y + b.y)/2 + Double(boundsMin.y))
            XCTAssertEqual(absolute.standardLine.distanceTo(sample), 0, accuracy: 1e-6,
                           "theta \(theta): the line drifted away from its own midpoint")
        }
    }
}
