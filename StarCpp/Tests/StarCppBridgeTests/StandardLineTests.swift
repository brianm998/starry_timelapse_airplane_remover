import XCTest
@testable import StarCppBridge

/// `StandardLine` (a*x + b*y + c = 0) is the form all the line-following code actually
/// computes in: `BoundingBox.intersections(with:)`, `Line.iterate`, the blob line trimming
/// and the horizon fitting all solve for x or y through it.  The interesting part is not
/// the algebra but the degenerate cases — a vertical line has b == 0 and a horizontal one
/// has a == 0, so exactly one of `y(forX:)` and `x(forY:)` divides by zero.  Callers rely
/// on getting an infinity there rather than a trap or a wrong finite number.
final class StandardLineTests: XCTestCase {

    // MARK: - construction from two points

    func testASlopedLinePassesThroughBothOfItsPoints() {
        let p1 = DoubleCoord(x: 0, y: 10)
        let p2 = DoubleCoord(x: 10, y: 0)
        let line = p1.standardLine(with: p2)

        XCTAssertEqual(line.distanceTo(p1), 0, accuracy: 1e-9)
        XCTAssertEqual(line.distanceTo(p2), 0, accuracy: 1e-9)
    }

    func testTheTwoPointInitializerAgreesWithTheCoordMethod() {
        let p1 = DoubleCoord(x: 3, y: -4)
        let p2 = DoubleCoord(x: -8, y: 15)
        XCTAssertTrue(StandardLine(point1: p1, point2: p2) == p1.standardLine(with: p2))
    }

    /// Swapping the two points describes the same line.  The blob code builds lines from
    /// whichever pixel it reached first, so this has to hold.
    func testPointOrderDoesNotChangeTheLine() {
        let p1 = DoubleCoord(x: 2, y: 7)
        let p2 = DoubleCoord(x: 11, y: -3)
        XCTAssertTrue(p1.standardLine(with: p2) == p2.standardLine(with: p1))
    }

    func testAVerticalLineIsRecognisedExactly() {
        let line = DoubleCoord(x: 5, y: 0).standardLine(with: DoubleCoord(x: 5, y: 100))
        // x = 5  ->  1*x + 0*y - 5 = 0
        XCTAssertEqual(line.a, 1)
        XCTAssertEqual(line.b, 0)
        XCTAssertEqual(line.c, -5)

        // solving for x works, solving for y cannot
        XCTAssertEqual(line.x(forY: 0), 5)
        XCTAssertEqual(line.x(forY: 1_000), 5)
        XCTAssertFalse(line.y(forX: 5).isFinite)
    }

    func testAHorizontalLineIsRecognisedExactly() {
        let line = DoubleCoord(x: 0, y: 7).standardLine(with: DoubleCoord(x: 100, y: 7))
        // y = 7  ->  0*x + 1*y - 7 = 0
        XCTAssertEqual(line.a, 0)
        XCTAssertEqual(line.b, 1)
        XCTAssertEqual(line.c, -7)

        XCTAssertEqual(line.y(forX: 0), 7)
        XCTAssertEqual(line.y(forX: -1_000), 7)
        XCTAssertFalse(line.x(forY: 7).isFinite)
    }

    /// A single point does not define a line.  `standardLine(with:)` takes the vertical
    /// branch (x_diff == 0 is checked first), so it answers "x = that point's x" rather
    /// than producing NaNs — worth pinning because it is the shape callers get for a
    /// one-pixel blob.
    func testTwoIdenticalPointsFallIntoTheVerticalBranch() {
        let p = DoubleCoord(x: 4, y: 9)
        let line = p.standardLine(with: p)
        XCTAssertEqual(line.a, 1)
        XCTAssertEqual(line.b, 0)
        XCTAssertEqual(line.c, -4)
    }

    // MARK: - solving

    func testSolvingForXAndYAreInverses() {
        let line = StandardLine(point1: DoubleCoord(x: 1, y: 2),
                                point2: DoubleCoord(x: 9, y: 30))
        for x in stride(from: -50.0, through: 50.0, by: 7.0) {
            let y = line.y(forX: x)
            XCTAssertEqual(line.x(forY: y), x, accuracy: 1e-6,
                           "x -> y -> x did not come back to \(x)")
        }
    }

    func testYAtZeroXMatchesSolvingForXAtZero() {
        let line = StandardLine(point1: DoubleCoord(x: -3, y: 4),
                                point2: DoubleCoord(x: 6, y: -8))
        XCTAssertEqual(line.yAtZeroX, line.y(forX: 0), accuracy: 1e-9)
    }

    // MARK: - distance

    func testDistanceFromTheOriginToTheClassicDiagonal() {
        // x + y = 10, whose closest approach to the origin is 10/sqrt(2)
        let line = StandardLine(point1: DoubleCoord(x: 0, y: 10),
                                point2: DoubleCoord(x: 10, y: 0))
        XCTAssertEqual(line.distanceTo(DoubleCoord(x: 0, y: 0)),
                       10 / 2.0.squareRoot(), accuracy: 1e-9)
    }

    func testDistanceIsUnsignedOnBothSidesOfTheLine() {
        let line = StandardLine(point1: DoubleCoord(x: 0, y: 0),
                                point2: DoubleCoord(x: 10, y: 10))   // y = x
        let above = DoubleCoord(x: 0, y: 4)
        let below = DoubleCoord(x: 4, y: 0)
        XCTAssertEqual(line.distanceTo(above), line.distanceTo(below), accuracy: 1e-9)
        XCTAssertGreaterThan(line.distanceTo(above), 0)
    }

    func testIntegerDistanceOverloadMatchesTheDoubleOne() {
        let line = StandardLine(point1: DoubleCoord(x: 1, y: 1),
                                point2: DoubleCoord(x: 20, y: 5))
        XCTAssertEqual(line.distanceTo(x: 7, y: 13),
                       line.distanceTo(DoubleCoord(x: 7, y: 13)),
                       accuracy: 1e-12)
    }

    func testDistanceToAPointOnTheLineIsZero() {
        let line = StandardLine(point1: DoubleCoord(x: -2, y: -2),
                                point2: DoubleCoord(x: 8, y: 18))
        let onIt = DoubleCoord(x: 3, y: line.y(forX: 3))
        XCTAssertEqual(line.distanceTo(onIt), 0, accuracy: 1e-9)
    }

    // MARK: - intersection

    func testTwoCrossingLinesMeetWhereBothEquationsHold() {
        let a = StandardLine(point1: DoubleCoord(x: 0, y: 0),
                             point2: DoubleCoord(x: 10, y: 10))     // y = x
        let b = StandardLine(point1: DoubleCoord(x: 0, y: 10),
                             point2: DoubleCoord(x: 10, y: 0))      // x + y = 10
        let meet = a.intersection(with: b)
        XCTAssertEqual(meet.x, 5, accuracy: 1e-9)
        XCTAssertEqual(meet.y, 5, accuracy: 1e-9)
        XCTAssertEqual(a.distanceTo(meet), 0, accuracy: 1e-9)
        XCTAssertEqual(b.distanceTo(meet), 0, accuracy: 1e-9)
    }

    func testIntersectionIsTheSameWhicheverLineIsAsked() {
        let a = StandardLine(point1: DoubleCoord(x: 1, y: 2), point2: DoubleCoord(x: 7, y: 20))
        let b = StandardLine(point1: DoubleCoord(x: 0, y: 9), point2: DoubleCoord(x: 12, y: 1))
        let ab = a.intersection(with: b)
        let ba = b.intersection(with: a)
        XCTAssertEqual(ab.x, ba.x, accuracy: 1e-9)
        XCTAssertEqual(ab.y, ba.y, accuracy: 1e-9)
    }

    /// Parallel lines give a non-rational point rather than a wrong finite one.  This is
    /// the case `DoubleCoord.isRational` exists to catch, and `BoundingBox.edgeDistance`
    /// leans on it.
    func testParallelLinesDoNotIntersectAtAFinitePoint() {
        let a = StandardLine(point1: DoubleCoord(x: 0, y: 0), point2: DoubleCoord(x: 10, y: 10))
        let b = StandardLine(point1: DoubleCoord(x: 0, y: 5), point2: DoubleCoord(x: 10, y: 15))
        XCTAssertFalse(a.intersection(with: b).isRational)
    }

    func testAVerticalAndAHorizontalLineMeetAtTheirCorner() {
        let vertical = DoubleCoord(x: 6, y: 0).standardLine(with: DoubleCoord(x: 6, y: 9))
        let horizontal = DoubleCoord(x: 0, y: 4).standardLine(with: DoubleCoord(x: 9, y: 4))
        let meet = vertical.intersection(with: horizontal)
        XCTAssertEqual(meet.x, 6, accuracy: 1e-9)
        XCTAssertEqual(meet.y, 4, accuracy: 1e-9)
    }

    // MARK: - equality

    /// Equality rounds to 8 decimal places, so it tolerates the drift that accumulates
    /// when a line is rebuilt through polar form and back.
    func testEqualityToleratesDriftBelowItsPrecision() {
        let a = StandardLine(a: 1, b: 2, c: 3)
        let b = StandardLine(a: 1 + 1e-12, b: 2 - 1e-12, c: 3 + 1e-12)
        XCTAssertTrue(a == b)
        XCTAssertFalse(a != b)
    }

    func testEqualityStillSeparatesGenuinelyDifferentLines() {
        let a = StandardLine(a: 1, b: 2, c: 3)
        XCTAssertTrue(a != StandardLine(a: 1, b: 2, c: 3.001))
        XCTAssertTrue(a != StandardLine(a: 1, b: 2.001, c: 3))
        XCTAssertTrue(a != StandardLine(a: 1.001, b: 2, c: 3))
    }

    /// The same line scaled by a constant is the same set of points but is *not* `==`.
    /// Callers comparing lines have to normalise first; pinning it so the assumption is
    /// visible rather than discovered.
    func testEqualityIsOnCoefficientsNotOnTheSetOfPoints() {
        XCTAssertTrue(StandardLine(a: 1, b: 2, c: 3) != StandardLine(a: 2, b: 4, c: 6))
    }

    // MARK: - Double.precised, which equality is built on

    func testPrecisedRoundsToTheRequestedNumberOfPlaces() {
        XCTAssertEqual(1.234_567_89.precised(2), 1.23, accuracy: 1e-12)
        XCTAssertEqual(1.235.precised(2), 1.24, accuracy: 1e-12)
        XCTAssertEqual((-1.235).precised(2), -1.24, accuracy: 1e-12)
    }

    func testEqualWithNoPrecisionIsExactComparison() {
        XCTAssertTrue(Double.equal(0.1, 0.1))
        XCTAssertFalse(Double.equal(0.1, 0.1 + 1e-18 + 1e-17))
        XCTAssertTrue(Double.equal(0.1, 0.100_000_001, precise: 3))
    }
}
