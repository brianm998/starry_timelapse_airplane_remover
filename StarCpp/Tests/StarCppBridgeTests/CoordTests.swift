import XCTest
@testable import StarCppBridge

/// `Coord` and `DoubleCoord` are the two value types every geometric decision in star is
/// phrased in — blob positions, bounding box corners, line intersections.  They are small
/// enough that nothing here is surprising, which is the point: the conversions between
/// them truncate rather than round, and code that assumes rounding gets answers that are
/// off by one in a direction that depends on sign.
final class CoordTests: XCTestCase {

    // MARK: - Coord

    func testDistanceIsSymmetricAndPythagorean() {
        let a = Coord(x: 0, y: 0)
        let b = Coord(x: 3, y: 4)
        XCTAssertEqual(a.distance(from: b), 5, accuracy: 1e-12)
        XCTAssertEqual(b.distance(from: a), 5, accuracy: 1e-12)
    }

    func testDistanceToItselfIsZero() {
        let a = Coord(x: -7, y: 12)
        XCTAssertEqual(a.distance(from: a), 0)
    }

    func testDistanceFromLooseCoordinatesMatchesDistanceFromCoord() {
        let a = Coord(x: 10, y: 20)
        XCTAssertEqual(a.distanceFrom(x: 13, y: 24),
                       a.distance(from: Coord(x: 13, y: 24)),
                       accuracy: 1e-12)
    }

    func testNegativeCoordinatesStillGiveAPositiveDistance() {
        let a = Coord(x: -3, y: -4)
        XCTAssertEqual(a.distance(from: Coord(x: 0, y: 0)), 5, accuracy: 1e-12)
    }

    func testEqualityComparesBothAxes() {
        XCTAssertEqual(Coord(x: 1, y: 2), Coord(x: 1, y: 2))
        XCTAssertNotEqual(Coord(x: 1, y: 2), Coord(x: 2, y: 1))
        XCTAssertNotEqual(Coord(x: 1, y: 2), Coord(x: 1, y: 3))
    }

    func testCoordSurvivesAJsonRoundTrip() throws {
        let original = Coord(x: -14, y: 9001)
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(Coord.self, from: data), original)
    }

    // MARK: - Coord <-> DoubleCoord

    /// `Coord(DoubleCoord)` uses `Int(_:)`, which truncates toward zero.  A blob at
    /// y = -0.5 lands on row 0, not row -1.
    func testConversionFromDoubleTruncatesTowardZero() {
        XCTAssertEqual(Coord(DoubleCoord(x: 1.9, y: 2.9)), Coord(x: 1, y: 2))
        XCTAssertEqual(Coord(DoubleCoord(x: -1.9, y: -2.9)), Coord(x: -1, y: -2))
        XCTAssertEqual(Coord(DoubleCoord(x: -0.5, y: 0.5)), Coord(x: 0, y: 0))
    }

    func testAnIntegerValuedDoubleCoordRoundTripsExactly() {
        let original = Coord(x: 42, y: -17)
        XCTAssertEqual(Coord(DoubleCoord(original)), original)
    }

    // MARK: - DoubleCoord

    func testDoubleDistanceIsPythagorean() {
        let a = DoubleCoord(x: 1, y: 1)
        let b = DoubleCoord(x: 4, y: 5)
        XCTAssertEqual(a.distance(to: b), 5, accuracy: 1e-12)
        XCTAssertEqual(b.distance(to: a), 5, accuracy: 1e-12)
    }

    func testDoubleDistanceToIntegerPairMatchesTheCoordOverload() {
        let a = DoubleCoord(x: 1.5, y: 2.5)
        XCTAssertEqual(a.distance(to: 4, and: 6),
                       a.distance(to: DoubleCoord(x: 4, y: 6)),
                       accuracy: 1e-12)
    }

    /// `isRational` is the guard the geometry code uses before trusting an intersection
    /// point, so each of its three ingredients has to behave.
    func testRationalityFlagsSeparateNaNFromInfinity() {
        let finite = DoubleCoord(x: 1, y: 2)
        XCTAssertFalse(finite.hasNaN)
        XCTAssertTrue(finite.isFinite)
        XCTAssertTrue(finite.isRational)

        let nan = DoubleCoord(x: .nan, y: 2)
        XCTAssertTrue(nan.hasNaN)
        XCTAssertFalse(nan.isFinite)   // NaN is not finite
        XCTAssertFalse(nan.isRational)

        let infinite = DoubleCoord(x: 1, y: .infinity)
        XCTAssertFalse(infinite.hasNaN)
        XCTAssertFalse(infinite.isFinite)
        XCTAssertFalse(infinite.isRational)

        // parallel lines produce -infinity as readily as +infinity
        XCTAssertFalse(DoubleCoord(x: -.infinity, y: 0).isRational)
    }

    func testDoubleCoordSurvivesAJsonRoundTrip() throws {
        let original = DoubleCoord(x: -1.25, y: 1e9)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(DoubleCoord.self, from: data)
        XCTAssertEqual(decoded.x, original.x)
        XCTAssertEqual(decoded.y, original.y)
    }
}
