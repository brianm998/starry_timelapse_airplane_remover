import XCTest
import StarCppBridge
@testable import StarCore

/// `BoundingBox` is the geometry every outlier group is described by: its size and hypotenuse
/// feed the decision tree, its overlap drives inter-frame matching, and its edge distance
/// decides whether two blobs get joined into one trail.  None of it was covered.
///
/// The single most important thing to know about it is that the bounds are *inclusive*, so a
/// box from 0 to 9 is ten pixels wide.  Most of the arithmetic below follows from that.
final class BoundingBoxTests: XCTestCase {

    private func box(_ minX: Int, _ minY: Int, _ maxX: Int, _ maxY: Int) -> BoundingBox {
        BoundingBox(min: Coord(x: minX, y: minY), max: Coord(x: maxX, y: maxY))
    }

    // MARK: - size

    func testBoundsAreInclusiveSoASinglePixelBoxHasSizeOne() {
        let single = box(5, 5, 5, 5)
        XCTAssertEqual(single.width, 1)
        XCTAssertEqual(single.height, 1)
        XCTAssertEqual(single.size, 1)
    }

    func testWidthAndHeightCountBothEndpoints() {
        let b = box(0, 0, 9, 4)
        XCTAssertEqual(b.width, 10)
        XCTAssertEqual(b.height, 5)
        XCTAssertEqual(b.size, 50)
    }

    func testSizeIsIndependentOfWhereTheBoxSits() {
        XCTAssertEqual(box(0, 0, 9, 4).size, box(100, 200, 109, 204).size)
        XCTAssertEqual(box(0, 0, 9, 4).width, box(-50, -50, -41, -46).width)
    }

    func testHypotenuseIsAcrossTheInclusiveExtent() {
        // 4 x 3 pixels, so the diagonal is 5
        let b = box(0, 0, 3, 2)
        XCTAssertEqual(b.width, 4)
        XCTAssertEqual(b.height, 3)
        XCTAssertEqual(b.hypotenuse, 5, accuracy: 1e-12)
    }

    func testHypotenuseOfASinglePixelIsTheUnitDiagonal() {
        XCTAssertEqual(box(7, 7, 7, 7).hypotenuse, 2.0.squareRoot(), accuracy: 1e-12)
    }

    // MARK: - zeroCentered

    /// `zeroCentered` moves a box to the origin without resizing it — it is how two boxes in
    /// different places are compared by shape.
    func testZeroCenteredMovesToTheOriginKeepingTheSize() {
        let moved = box(100, 200, 109, 204).zeroCentered
        XCTAssertEqual(moved.min, Coord(x: 0, y: 0))
        XCTAssertEqual(moved.max, Coord(x: 9, y: 4))
        XCTAssertEqual(moved.width, 10)
        XCTAssertEqual(moved.height, 5)
    }

    func testZeroCenteringAnAlreadyOriginBoxChangesNothing() {
        let b = box(0, 0, 9, 4)
        XCTAssertEqual(b.zeroCentered, b)
    }

    func testTwoBoxesOfTheSameShapeZeroCenterEqual() {
        XCTAssertEqual(box(0, 0, 9, 4).zeroCentered, box(500, 600, 509, 604).zeroCentered)
    }

    // MARK: - centre

    /// The centre is `min + width/2`, which for an inclusive box overshoots the true midpoint
    /// by half a pixel: 0...9 centres on 5.0 rather than 4.5.  Pinned because the decision
    /// tree consumes these values and a change would move every stored feature.
    func testTheCentreIsHalfAPixelPastTheTrueMidpoint() {
        let b = box(0, 0, 9, 9)
        XCTAssertEqual(b.centerDouble.x, 5.0)
        XCTAssertEqual(b.centerDouble.y, 5.0)
        XCTAssertEqual(b.center, Coord(x: 5, y: 5))
    }

    func testTheIntegerCentreTruncatesTheDoubleOne() {
        let b = box(0, 0, 8, 8)   // width 9, so centre is 4.5
        XCTAssertEqual(b.centerDouble.x, 4.5)
        XCTAssertEqual(b.center, Coord(x: 4, y: 4))
    }

    func testASinglePixelBoxCentresOnItself() {
        let b = box(3, 7, 3, 7)
        XCTAssertEqual(b.centerDouble.x, 3.5)
        XCTAssertEqual(b.center, Coord(x: 3, y: 7))
    }

    func testCentreDistanceIsSymmetricAndPythagorean() {
        let a = box(0, 0, 1, 1)     // centre 1.0, 1.0
        let b = box(3, 4, 4, 5)     // centre 4.0, 5.0
        XCTAssertEqual(a.centerDistance(to: b), 5, accuracy: 1e-12)
        XCTAssertEqual(b.centerDistance(to: a), 5, accuracy: 1e-12)
    }

    func testCentreDistanceToItselfIsZero() {
        let b = box(10, 20, 30, 40)
        XCTAssertEqual(b.centerDistance(to: b), 0)
    }

    func testCentreDistanceAgreesWithTheCentreProperty() {
        let a = box(0, 0, 5, 5), b = box(20, 30, 25, 35)
        XCTAssertEqual(a.centerDistance(to: b),
                       a.centerDouble.distance(to: b.centerDouble),
                       accuracy: 1e-12)
    }

    // MARK: - containment

    func testAPointInsideIsContainedAndTheBoundsCount() {
        let b = box(10, 20, 30, 40)
        XCTAssertTrue(b.contains(x: 20, y: 30))
        XCTAssertTrue(b.contains(x: 10, y: 20), "the minimum corner is inside")
        XCTAssertTrue(b.contains(x: 30, y: 40), "the maximum corner is inside")
    }

    func testAPointOutsideIsNotContained() {
        let b = box(10, 20, 30, 40)
        XCTAssertFalse(b.contains(x: 9, y: 30))
        XCTAssertFalse(b.contains(x: 31, y: 30))
        XCTAssertFalse(b.contains(x: 20, y: 19))
        XCTAssertFalse(b.contains(x: 20, y: 41))
    }

    func testABoxContainsASmallerBoxInsideIt() {
        let outer = box(0, 0, 100, 100)
        XCTAssertTrue(outer.contains(other: box(10, 10, 90, 90)))
        XCTAssertTrue(outer.contains(other: outer), "containment is not strict")
    }

    func testABoxDoesNotContainOneThatSticksOut() {
        let outer = box(0, 0, 100, 100)
        XCTAssertFalse(outer.contains(other: box(10, 10, 101, 90)))
        XCTAssertFalse(outer.contains(other: box(-1, 10, 90, 90)))
        XCTAssertFalse(outer.contains(other: box(200, 200, 300, 300)))
    }

    func testContainmentIsAsymmetric() {
        let outer = box(0, 0, 100, 100), inner = box(10, 10, 20, 20)
        XCTAssertTrue(outer.contains(other: inner))
        XCTAssertFalse(inner.contains(other: outer))
    }

    func testAPixelInsideTheBoxIsContained() {
        let b = box(10, 10, 20, 20)
        XCTAssertTrue(b.contains(SortablePixel(x: 15, y: 15, value: .eightBit(1))))
        XCTAssertTrue(b.contains(SortablePixel(x: 10, y: 20, value: .eightBit(1))))
        XCTAssertFalse(b.contains(SortablePixel(x: 21, y: 15, value: .eightBit(1))))
    }

    /// `contains(coord:)` truncates to whole pixels first, so a fractional coordinate just
    /// past the far edge still lands on the last row or column.  That is the right behaviour
    /// for an intersection point on a box boundary, but it means the effective bound is
    /// `max + 1` exclusive rather than `max` inclusive.
    func testAFiniteCoordIsContainedAfterTruncationToAPixel() {
        let b = box(10, 10, 20, 20)
        XCTAssertTrue(b.contains(coord: DoubleCoord(x: 15.5, y: 15.5)))
        XCTAssertTrue(b.contains(coord: DoubleCoord(x: 20.5, y: 15)),
                      "20.5 truncates to 20, which is the last column")
        XCTAssertTrue(b.contains(coord: DoubleCoord(x: 20.99, y: 20.99)))

        XCTAssertFalse(b.contains(coord: DoubleCoord(x: 21, y: 15)))
        XCTAssertFalse(b.contains(coord: DoubleCoord(x: 9.5, y: 15)),
                       "9.5 truncates to 9, which is outside")
    }

    /// A non-rational coordinate is what a parallel-line intersection produces, and it must
    /// never be reported as inside.
    func testANonRationalCoordIsNeverContained() {
        let b = box(0, 0, 100, 100)
        XCTAssertFalse(b.contains(coord: DoubleCoord(x: .nan, y: 50)))
        XCTAssertFalse(b.contains(coord: DoubleCoord(x: .infinity, y: 50)))
        XCTAssertFalse(b.contains(coord: DoubleCoord(x: 50, y: -.infinity)))
    }

    // MARK: - overlap

    func testTwoOverlappingBoxesGiveTheirIntersection() throws {
        let a = box(0, 0, 10, 10)
        let b = box(5, 5, 15, 15)
        let overlap = try XCTUnwrap(a.overlap(with: b))
        XCTAssertEqual(overlap, box(5, 5, 10, 10))
        XCTAssertEqual(overlap.size, 36)
    }

    func testOverlapIsCommutative() throws {
        let a = box(0, 0, 10, 10), b = box(5, 5, 15, 15)
        XCTAssertEqual(try XCTUnwrap(a.overlap(with: b)), try XCTUnwrap(b.overlap(with: a)))
    }

    func testABoxFullyInsideAnotherOverlapsAsItself() throws {
        let outer = box(0, 0, 100, 100), inner = box(10, 10, 20, 20)
        XCTAssertEqual(try XCTUnwrap(outer.overlap(with: inner)), inner)
    }

    func testABoxOverlapsItselfEntirely() throws {
        let b = box(3, 4, 30, 40)
        XCTAssertEqual(try XCTUnwrap(b.overlap(with: b)), b)
    }

    func testSeparatedBoxesDoNotOverlap() {
        XCTAssertNil(box(0, 0, 5, 5).overlap(with: box(10, 10, 15, 15)))
        XCTAssertNil(box(0, 0, 5, 5).overlap(with: box(10, 0, 15, 5)), "separated in x only")
        XCTAssertNil(box(0, 0, 5, 5).overlap(with: box(0, 10, 5, 15)), "separated in y only")
    }

    /// `overlap(with:)` compares with strict `<`, so boxes that merely touch at a corner or
    /// share an edge coordinate are not treated as overlapping.
    func testBoxesThatOnlyTouchDoNotOverlap() {
        XCTAssertNil(box(0, 0, 5, 5).overlap(with: box(5, 5, 10, 10)))
        XCTAssertNil(box(0, 0, 5, 5).overlap(with: box(5, 0, 10, 5)))
    }

    func testOverlapAmountIsTheSharedAreaOverTheAverageSize() {
        let a = box(0, 0, 10, 10)   // 11 x 11 = 121
        let b = box(5, 5, 15, 15)   // 121
        // shared is 6 x 6 = 36, average size is 121
        XCTAssertEqual(a.overlapAmount(with: b), 36.0 / 121.0, accuracy: 1e-12)
    }

    func testABoxFullyOverlapsItself() {
        let b = box(0, 0, 9, 9)
        XCTAssertEqual(b.overlapAmount(with: b), 1, accuracy: 1e-12)
    }

    func testSeparatedBoxesHaveNoOverlapAmount() {
        XCTAssertEqual(box(0, 0, 5, 5).overlapAmount(with: box(20, 20, 25, 25)), 0)
    }

    /// A small box inside a big one can exceed... no: the average size denominator keeps the
    /// ratio at or below 1 for equal boxes, but a small box inside a large one scores low even
    /// though it is entirely contained.  Callers using this as "is this the same blob" need to
    /// know it is size sensitive.
    func testASmallBoxInsideALargeOneScoresLowDespiteBeingContained() {
        let large = box(0, 0, 99, 99)   // 10000
        let small = box(10, 10, 19, 19) // 100
        XCTAssertTrue(large.contains(other: small))
        let amount = large.overlapAmount(with: small)
        XCTAssertEqual(amount, 100.0 / 5050.0, accuracy: 1e-12)
        XCTAssertLessThan(amount, 0.02)
    }

    // MARK: - overlaps(_:), the boolean form of overlap(with:)

    /// `overlaps(_:)` is the cheap predicate form of `overlap(with:)`, and the contract worth
    /// pinning is that the two agree: a box shares area iff the predicate says so.
    ///
    /// This is a regression test.  The original condition asked for
    ///     self.min.x <= other.min.x && self.min.x >= other.max.x
    /// which needs `other.max.x <= other.min.x` — unsatisfiable for any box wider than a single
    /// column — so it answered false for every real pair, including a box against itself.
    func testOverlapsAgreesWithOverlapWith() {
        let pairs: [(BoundingBox, BoundingBox)] = [
          (box(0, 0, 10, 10),   box(5, 5, 15, 15)),      // corner overlap
          (box(0, 0, 10, 4),    box(6, 0, 16, 4)),       // horizontal overlap
          (box(0, 0, 4, 10),    box(0, 6, 4, 16)),       // vertical overlap
          (box(0, 0, 100, 100), box(10, 10, 20, 20)),    // nested
          (box(0, 0, 20, 20),   box(10, 5, 30, 25)),     // offset overlap
          (box(0, 0, 10, 4),    box(20, 0, 30, 4)),      // gap in x
          (box(0, 0, 4, 10),    box(0, 30, 4, 40)),       // gap in y
          (box(0, 0, 10, 4),    box(10, 0, 20, 4)),      // touching along an edge
          (box(0, 0, 5, 5),     box(5, 5, 10, 10)),      // touching at a corner
          (box(0, 0, 10, 10),   box(100, 100, 110, 110)), // far apart
        ]
        for (a, b) in pairs {
            let sharesArea = a.overlap(with: b) != nil
            XCTAssertEqual(a.overlaps(b), sharesArea,
                           "\(a) vs \(b): overlaps says \(a.overlaps(b)) but overlap(with:) "
                           + "says \(sharesArea)")
            XCTAssertEqual(b.overlaps(a), sharesArea, "\(a) vs \(b): not symmetric")
        }
    }

    func testOverlappingBoxesAreReportedAsOverlapping() {
        XCTAssertTrue(box(0, 0, 10, 10).overlaps(box(5, 5, 15, 15)))
        XCTAssertTrue(box(0, 0, 100, 100).overlaps(box(10, 10, 20, 20)), "a nested box overlaps")
        XCTAssertTrue(box(10, 10, 20, 20).overlaps(box(0, 0, 100, 100)), "and the other way round")
        XCTAssertTrue(box(0, 0, 10, 10).overlaps(box(0, 0, 10, 10)), "a box overlaps itself")
    }

    func testSeparatedBoxesAreNotReportedAsOverlapping() {
        XCTAssertFalse(box(0, 0, 5, 5).overlaps(box(10, 10, 15, 15)))
        XCTAssertFalse(box(0, 0, 5, 5).overlaps(box(10, 0, 15, 5)), "separated in x only")
        XCTAssertFalse(box(0, 0, 5, 5).overlaps(box(0, 10, 5, 15)), "separated in y only")
    }

    /// Like `overlap(with:)`, the comparison is strict, so boxes sharing only an edge or a
    /// corner are not overlapping.  Keeping the two consistent matters more than which
    /// convention is picked.
    func testBoxesThatOnlyTouchAreNotOverlapping() {
        XCTAssertFalse(box(0, 0, 5, 5).overlaps(box(5, 5, 10, 10)))
        XCTAssertFalse(box(0, 0, 5, 5).overlaps(box(5, 0, 10, 5)))
    }

    /// A consequence of that strictness, inherited from `overlap(with:)`: a one-pixel box does
    /// not overlap *itself*, because the strict comparison needs `min < max` on both boxes.
    /// It does still overlap a larger box it sits inside, which is the case that matters.
    func testASinglePixelBoxDoesNotOverlapItselfButDoesOverlapABoxAroundIt() {
        let pixel = box(5, 5, 5, 5)

        XCTAssertNil(pixel.overlap(with: pixel))
        XCTAssertFalse(pixel.overlaps(pixel), "and overlaps agrees, which is the point")

        let around = box(0, 0, 10, 10)
        XCTAssertNotNil(around.overlap(with: pixel))
        XCTAssertTrue(around.overlaps(pixel))
        XCTAssertTrue(pixel.overlaps(around))
    }

    // MARK: - centerTheta

    func testHorizontallyAlignedCentresAreThetaZero() {
        let a = box(0, 0, 10, 10)
        let b = box(100, 0, 110, 10)
        XCTAssertEqual(a.centerTheta(with: b), 0)
    }

    func testVerticallyAlignedCentresAreTheta90() {
        let a = box(0, 0, 10, 10)
        let b = box(0, 100, 10, 110)
        XCTAssertEqual(a.centerTheta(with: b), 90)
    }

    func testADiagonalPairIs45Degrees() {
        let a = box(0, 0, 10, 10)      // centre 5.5, 5.5
        let b = box(100, 100, 110, 110) // centre 105.5, 105.5
        // equal width and height offsets, and the centre is below-right, so the 90+ branch
        XCTAssertEqual(a.centerTheta(with: b), 135, accuracy: 1e-9)
    }

    func testThetaIsSymmetric() {
        let a = box(0, 0, 10, 10), b = box(50, 90, 60, 100)
        XCTAssertEqual(a.centerTheta(with: b), b.centerTheta(with: a), accuracy: 1e-9)
    }

    func testThetaStaysWithinASemicircle() {
        let a = box(0, 0, 10, 10)
        for dx in [-100, -30, 0, 30, 100] {
            for dy in [-100, -30, 0, 30, 100] where !(dx == 0 && dy == 0) {
                let b = box(dx, dy, dx + 10, dy + 10)
                let theta = a.centerTheta(with: b)
                XCTAssertGreaterThanOrEqual(theta, 0, "theta \(theta) for offset \(dx),\(dy)")
                XCTAssertLessThanOrEqual(theta, 180, "theta \(theta) for offset \(dx),\(dy)")
            }
        }
    }

    // MARK: - intersections with a line

    func testAHorizontalLineThroughABoxCrossesBothVerticalEdges() {
        let b = box(0, 0, 10, 10)
        let line = DoubleCoord(x: -50, y: 5).standardLine(with: DoubleCoord(x: 50, y: 5))
        let points = b.intersections(with: line)

        XCTAssertEqual(points.count, 2)
        XCTAssertEqual(Set(points.map { $0.x }), [0, 10])
        for point in points { XCTAssertEqual(point.y, 5, accuracy: 1e-9) }
    }

    func testAVerticalLineThroughABoxCrossesBothHorizontalEdges() {
        let b = box(0, 0, 10, 10)
        let line = DoubleCoord(x: 5, y: -50).standardLine(with: DoubleCoord(x: 5, y: 50))
        let points = b.intersections(with: line)

        XCTAssertEqual(points.count, 2)
        XCTAssertEqual(Set(points.map { $0.y }), [0, 10])
        for point in points { XCTAssertEqual(point.x, 5, accuracy: 1e-9) }
    }

    /// A line that misses the box entirely must report no crossings, or the edge-distance
    /// code would pick a point that is not on the box.
    func testALineThatMissesTheBoxHasNoIntersections() {
        let b = box(0, 0, 10, 10)
        let line = DoubleCoord(x: -50, y: 500).standardLine(with: DoubleCoord(x: 50, y: 500))
        XCTAssertTrue(b.intersections(with: line).isEmpty)
    }

    func testEveryReportedIntersectionIsOnTheLineAndOnTheBoxBoundary() {
        let b = box(10, 20, 40, 60)
        let line = DoubleCoord(x: 0, y: 10).standardLine(with: DoubleCoord(x: 100, y: 90))
        let points = b.intersections(with: line)

        XCTAssertFalse(points.isEmpty)
        for point in points {
            XCTAssertEqual(line.distanceTo(point), 0, accuracy: 1e-6,
                           "\(point) is not on the line")
            let onVerticalEdge = abs(point.x - 10) < 1e-9 || abs(point.x - 40) < 1e-9
            let onHorizontalEdge = abs(point.y - 20) < 1e-9 || abs(point.y - 60) < 1e-9
            XCTAssertTrue(onVerticalEdge || onHorizontalEdge, "\(point) is not on an edge")
        }
    }

    /// `allIntersections` skips the range checks and always returns four points, which is what
    /// makes it usable when the caller wants to reason about a line that misses the box.
    func testAllIntersectionsAlwaysReturnsFourPoints() {
        let b = box(0, 0, 10, 10)
        let missing = DoubleCoord(x: -50, y: 500).standardLine(with: DoubleCoord(x: 50, y: 500))
        XCTAssertEqual(b.allIntersections(with: missing).count, 4)

        let crossing = DoubleCoord(x: -50, y: 5).standardLine(with: DoubleCoord(x: 50, y: 5))
        XCTAssertEqual(b.allIntersections(with: crossing).count, 4)
    }

    /// A horizontal line has no solution for x, so two of the four come back non-rational.
    /// That is the case `DoubleCoord.isRational` exists to filter.
    func testAllIntersectionsWithAnAxisAlignedLineIncludesNonRationalPoints() {
        let b = box(0, 0, 10, 10)
        let horizontal = DoubleCoord(x: -50, y: 5).standardLine(with: DoubleCoord(x: 50, y: 5))
        let points = b.allIntersections(with: horizontal)
        XCTAssertEqual(points.filter { $0.isRational }.count, 2)
        XCTAssertEqual(points.filter { !$0.isRational }.count, 2)
    }

    // MARK: - equality and codable

    func testEqualityComparesBothCorners() {
        XCTAssertEqual(box(1, 2, 3, 4), box(1, 2, 3, 4))
        XCTAssertNotEqual(box(1, 2, 3, 4), box(1, 2, 3, 5))
        XCTAssertNotEqual(box(1, 2, 3, 4), box(0, 2, 3, 4))
    }

    /// Bounding boxes are stored in the outlier group json, so a round trip has to be exact.
    func testABoundingBoxSurvivesAJsonRoundTrip() throws {
        let original = box(-5, 10, 1000, 2000)
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(BoundingBox.self, from: data), original)
    }

    // MARK: - construction from two screen points

    /// The gui builds a box from a drag, where the end point may be above or left of the
    /// start.  Either ordering has to give the same box.
    func testABoxFromTwoScreenPointsIsIndependentOfDragDirection() {
        let downRight = BoundingBox(between: CGPoint(x: 10, y: 20), and: CGPoint(x: 110, y: 220))
        let upLeft = BoundingBox(between: CGPoint(x: 110, y: 220), and: CGPoint(x: 10, y: 20))
        XCTAssertEqual(downRight, upLeft)
        XCTAssertEqual(downRight.min, Coord(x: 10, y: 20))
        XCTAssertEqual(downRight.max, Coord(x: 110, y: 220))
    }

    func testABoxFromTwoScreenPointsTruncatesToWholePixels() {
        let b = BoundingBox(between: CGPoint(x: 10.9, y: 20.9), and: CGPoint(x: 110.9, y: 220.9))
        XCTAssertEqual(b.min, Coord(x: 10, y: 20))
        XCTAssertEqual(b.max, Coord(x: 110, y: 220))
    }

    func testAZeroLengthDragGivesASinglePixelBox() {
        let b = BoundingBox(between: CGPoint(x: 42, y: 42), and: CGPoint(x: 42, y: 42))
        XCTAssertEqual(b.size, 1)
    }

    // MARK: - edgeDistance

    /// The headline behaviour: boxes that are apart get a positive distance, and one nested
    /// inside another gets the negative of the inner box's size.
    func testANestedBoxGetsTheNegativeOfTheInnerSize() {
        let outer = box(0, 0, 100, 100)
        let inner = box(40, 40, 49, 49)   // 10 x 10 = 100
        XCTAssertEqual(outer.edgeDistance(to: inner), -100)
        XCTAssertEqual(inner.edgeDistance(to: outer), -100)
    }

    func testSeparatedBoxesGetAPositiveEdgeDistance() {
        let a = box(0, 0, 10, 10)
        let b = box(100, 0, 110, 10)
        XCTAssertGreaterThan(a.edgeDistance(to: b), 0)
    }

    /// The gap between two boxes on the same row is the distance between their facing edges,
    /// not between their centres.
    func testTheEdgeDistanceOfTwoBoxesOnARowIsTheGapBetweenThem() {
        let a = box(0, 0, 10, 10)
        let b = box(100, 0, 110, 10)
        // facing edges are x 10 and x 100
        XCTAssertEqual(a.edgeDistance(to: b), 90, accuracy: 1.0)
        XCTAssertLessThan(a.edgeDistance(to: b), a.centerDistance(to: b))
    }

    func testEdgeDistanceIsRoughlySymmetric() {
        let a = box(0, 0, 10, 10)
        let b = box(60, 80, 70, 90)
        XCTAssertEqual(a.edgeDistance(to: b), b.edgeDistance(to: a), accuracy: 1.0)
    }

    func testFartherBoxesHaveLargerEdgeDistances() {
        let a = box(0, 0, 10, 10)
        let near = box(50, 0, 60, 10)
        let far = box(500, 0, 510, 10)
        XCTAssertLessThan(a.edgeDistance(to: near), a.edgeDistance(to: far))
    }

    func testEdgeDistanceOfABoxToItselfIsItsNegativeSize() {
        let b = box(10, 10, 19, 19)
        XCTAssertEqual(b.edgeDistance(to: b), -100, "a box contains itself")
    }

    /// Overlapping boxes get the negative *depth* of the overlap, not the span of their union.
    ///
    /// This is the distinction that made fixing `overlaps(_:)` delicate: `edgeDistance` had a
    /// second, unreachable branch keyed on that predicate which took the far side of each box
    /// instead of the near side, and enabling it would have turned these -4s into -16s.  The
    /// branch was removed rather than switched on, so these values are unchanged by that fix.
    func testAnOverlapIsMeasuredByItsDepthNotByTheUnion() {
        // x 6...10 is shared, so the depth along the centre line is 4
        XCTAssertEqual(box(0, 0, 10, 4).edgeDistance(to: box(6, 0, 16, 4)), -4, accuracy: 1e-9)
        // the same, rotated
        XCTAssertEqual(box(0, 0, 4, 10).edgeDistance(to: box(0, 6, 4, 16)), -4, accuracy: 1e-9)

        // and it is far smaller than the union those two boxes span
        let union = box(0, 0, 10, 4).centerDistance(to: box(6, 0, 16, 4)) * 2
        XCTAssertLessThan(abs(box(0, 0, 10, 4).edgeDistance(to: box(6, 0, 16, 4))), union)
    }

    func testAnOverlapDeepensAsTheBoxesSlideTogether() {
        let fixed = box(0, 0, 20, 4)
        var previous = 0.0
        for offset in [16, 12, 8, 4] {
            let moving = box(offset, 0, offset + 20, 4)
            let distance = fixed.edgeDistance(to: moving)
            XCTAssertLessThan(distance, 0, "these boxes overlap at offset \(offset)")
            XCTAssertLessThan(distance, previous,
                              "sliding from the previous offset to \(offset) should deepen it")
            previous = distance
        }
    }

    /// A gap is still positive, and it still grows with separation — the sign convention is the
    /// part callers depend on, since `OutlierGroup` clamps anything below 1 to 1.
    func testTheSignSeparatesAGapFromAnOverlap() {
        let fixed = box(0, 0, 10, 4)
        XCTAssertGreaterThan(fixed.edgeDistance(to: box(20, 0, 30, 4)), 0, "a gap is positive")
        XCTAssertLessThan(fixed.edgeDistance(to: box(6, 0, 16, 4)), 0, "an overlap is negative")
        XCTAssertLessThan(fixed.edgeDistance(to: box(2, 1, 8, 3)), 0, "a nested box is negative")
    }
}
