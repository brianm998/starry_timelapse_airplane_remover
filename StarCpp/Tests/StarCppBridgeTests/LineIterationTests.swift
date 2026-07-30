import XCTest
@testable import StarCppBridge

/// `Line+Iteration` walks the pixels under a line.  It is what the blob line trimming and
/// the linear blob extension use to decide which pixels belong to an airplane trail, so an
/// off-by-one or a skipped row here shows up as a trail that is cut short.
///
/// The key structural decision is `iterationOrientation`: iterate along whichever axis the
/// line covers more of, so that a nearly-vertical line does not step x by one and jump y by
/// a hundred.  Everything else follows from that choice.
///
/// Every line here is deliberately kept off the origin.  `polarCoords` cannot describe a
/// line through [0, 0] — see `LineTests.testALineThroughTheOriginCannotBeDescribed` — and a
/// walk along such a line silently visits nothing, which would make these tests vacuous
/// rather than failing.
final class LineIterationTests: XCTestCase {

    /// y = 0.4x + 10 — shallow, so the walk is driven by x.
    private let shallow = Line(point1: DoubleCoord(x: 0, y: 10), point2: DoubleCoord(x: 100, y: 50))

    /// y = 2.5x - 25 — steep, so the walk is driven by y.
    private let steep = Line(point1: DoubleCoord(x: 10, y: 0), point2: DoubleCoord(x: 50, y: 100))

    // MARK: - orientation

    /// The rule that falls out of the implementation: a line flatter than 45 degrees is
    /// walked along x, a steeper one along y.  `twoPoints` puts x_diff at rho*|sin(theta)|
    /// and y_diff at rho*|cos(theta)|, so the comparison is really |slope| against 1.
    func testAShallowLineIteratesHorizontally() {
        XCTAssertEqual(shallow.iterationOrientation, .horizontal)
        XCTAssertEqual(Line(point1: DoubleCoord(x: 0, y: 100),
                            point2: DoubleCoord(x: 1000, y: 110)).iterationOrientation, .horizontal)
    }

    func testASteepLineIteratesVertically() {
        XCTAssertEqual(steep.iterationOrientation, .vertical)
        XCTAssertEqual(Line(point1: DoubleCoord(x: 100, y: 0),
                            point2: DoubleCoord(x: 110, y: 1000)).iterationOrientation, .vertical)
    }

    func testAPurelyHorizontalLineIteratesHorizontally() {
        XCTAssertEqual(Line(theta: 90, rho: 50).iterationOrientation, .horizontal)
    }

    func testAPurelyVerticalLineIteratesVertically() {
        XCTAssertEqual(Line(theta: 0, rho: 50).iterationOrientation, .vertical)
    }

    /// At exactly 45 degrees x_diff and y_diff are equal in exact arithmetic, so which side
    /// the `x_diff > y_diff` comparison falls on is decided by floating point noise in
    /// `sin`/`cos`.  Rather than pin that, check that the orientation is settled just either
    /// side of the tie — which is what any real line will be.
    func testTheOrientationFlipsEitherSideOfTheDiagonal() {
        XCTAssertEqual(Line(theta: 46, rho: 30).iterationOrientation, .horizontal)
        XCTAssertEqual(Line(theta: 44, rho: 30).iterationOrientation, .vertical)
    }

    // MARK: - iterate(between:and:)

    /// The bounded walk is the one the blob code actually calls.  It should visit one pixel
    /// per step of the driving axis, and each visited pixel should be on the line.
    func testABoundedWalkVisitsEveryStepAlongTheDrivingAxis() {
        var visited: [(Int, Int)] = []
        shallow.iterate(between: DoubleCoord(x: 10, y: 14),
                        and: DoubleCoord(x: 20, y: 18)) { x, y, orientation in
            XCTAssertEqual(orientation, .horizontal)
            visited.append((x, y))
        }

        XCTAssertEqual(visited.map { $0.0 }, Array(10...20),
                       "a horizontal walk should step x by one from 10 through 20")

        let standard = shallow.standardLine
        for (x, y) in visited {
            XCTAssertEqual(Double(y), standard.y(forX: Double(x)), accuracy: 1.0,
                           "pixel [\(x), \(y)] is not under the line")
        }
    }

    /// Endpoint order must not matter — callers pass whichever blob end they found first.
    func testABoundedWalkCoversTheSameGroundInEitherOrder() {
        let a = DoubleCoord(x: 5, y: 12), b = DoubleCoord(x: 25, y: 20)

        var forward: [String] = [], backward: [String] = []
        shallow.iterate(between: a, and: b) { x, y, _ in forward.append("\(x),\(y)") }
        shallow.iterate(between: b, and: a) { x, y, _ in backward.append("\(x),\(y)") }

        XCTAssertEqual(forward.count, 21)
        XCTAssertEqual(forward, backward)
    }

    func testAVerticalWalkIsDrivenByY() {
        var ys: [Int] = []
        steep.iterate(between: DoubleCoord(x: 14, y: 10),
                      and: DoubleCoord(x: 22, y: 30)) { _, y, orientation in
            XCTAssertEqual(orientation, .vertical)
            ys.append(y)
        }
        XCTAssertEqual(ys, Array(10...30))
    }

    func testAVerticalWalkTracksXAlongTheLine() {
        let standard = steep.standardLine
        steep.iterate(between: DoubleCoord(x: 14, y: 10),
                      and: DoubleCoord(x: 22, y: 30)) { x, y, _ in
            XCTAssertEqual(Double(x), standard.x(forY: Double(y)), accuracy: 1.0,
                           "pixel [\(x), \(y)] is not on the line")
        }
    }

    /// Negative pixels are off the image, and the walk drops them rather than handing a
    /// caller an index that would trap on an array.
    func testABoundedWalkSkipsNegativePixels() {
        var visited: [(Int, Int)] = []
        shallow.iterate(between: DoubleCoord(x: -10, y: 6),
                        and: DoubleCoord(x: 10, y: 14)) { x, y, _ in
            visited.append((x, y))
        }
        XCTAssertEqual(visited.map { $0.0 }, Array(0...10),
                       "the walk should start at x 0, not at x -10")
        for (x, y) in visited {
            XCTAssertGreaterThanOrEqual(x, 0)
            XCTAssertGreaterThanOrEqual(y, 0)
        }
    }

    /// `numberOfAdjecentPixels` widens the walk perpendicular to the driving axis, which is
    /// how the trail trimming looks at a band rather than a single-pixel line.
    func testAdjacentPixelsWidenTheWalkPerpendicularly() {
        let line = Line(point1: DoubleCoord(x: 0, y: 100), point2: DoubleCoord(x: 100, y: 130))
        let from = DoubleCoord(x: 20, y: 106), to = DoubleCoord(x: 30, y: 109)

        var narrow: [(Int, Int)] = [], wide: [(Int, Int)] = []
        line.iterate(between: from, and: to) { x, y, _ in narrow.append((x, y)) }
        line.iterate(between: from, and: to, numberOfAdjecentPixels: 2) { x, y, _ in wide.append((x, y)) }

        XCTAssertEqual(narrow.count, 11)
        XCTAssertEqual(wide.count, 11 * 5, "2 adjacent pixels each side means 5 rows per step")

        // the widening is in y, because this line is driven by x
        XCTAssertEqual(Set(wide.map { $0.0 }), Set(narrow.map { $0.0 }))
        for (x, centreY) in narrow {
            for offset in -2...2 {
                XCTAssertTrue(wide.contains { $0 == (x, centreY + offset) },
                              "the band around [\(x), \(centreY)] is missing y \(centreY + offset)")
            }
        }
    }

    func testAdjacentPixelsWidenAVerticalWalkInX() {
        let from = DoubleCoord(x: 14, y: 10), to = DoubleCoord(x: 18, y: 20)

        var narrow: [(Int, Int)] = [], wide: [(Int, Int)] = []
        steep.iterate(between: from, and: to) { x, y, _ in narrow.append((x, y)) }
        steep.iterate(between: from, and: to, numberOfAdjecentPixels: 1) { x, y, _ in wide.append((x, y)) }

        XCTAssertEqual(narrow.count, 11)
        XCTAssertEqual(wide.count, 11 * 3)
        XCTAssertEqual(Set(wide.map { $0.1 }), Set(narrow.map { $0.1 }),
                       "a vertical walk widens in x, so the set of y values is unchanged")
    }

    // MARK: - findSpot

    func testFindSpotReturnsTheFirstPixelMatchingThePredicate() {
        let found = shallow.findSpot(between: DoubleCoord(x: 0, y: 10),
                                     and: DoubleCoord(x: 40, y: 26),
                                     closure: { x, _ in x >= 12 })
        XCTAssertEqual(found?.x, 12)
    }

    func testFindSpotIsNilWhenNothingMatches() {
        XCTAssertNil(shallow.findSpot(between: DoubleCoord(x: 0, y: 10),
                                      and: DoubleCoord(x: 40, y: 26),
                                      closure: { _, _ in false }))
    }

    func testFindSpotReturnsAPointThatIsOnTheLine() throws {
        let found = try XCTUnwrap(shallow.findSpot(between: DoubleCoord(x: 0, y: 10),
                                                  and: DoubleCoord(x: 50, y: 30),
                                                  closure: { x, _ in x == 20 }))
        XCTAssertEqual(Double(found.y),
                       shallow.standardLine.y(forX: 20),
                       accuracy: 1.0)
    }

    func testFindSpotSearchesAVerticalLineByY() {
        let found = steep.findSpot(between: DoubleCoord(x: 14, y: 10),
                                   and: DoubleCoord(x: 22, y: 30),
                                   closure: { _, y in y >= 25 })
        XCTAssertEqual(found?.y, 25)
    }

    // MARK: - iterate(_:from:) — the unbounded walk

    /// The open-ended walk runs until the closure says stop; the closure is the only brake,
    /// so a caller that always returns true would spin forever.  This pins that the stop
    /// actually takes effect and that direction is honoured.
    func testAnUnboundedForwardWalkStopsWhenTheClosureSaysSo() {
        var xs: [Int] = []
        shallow.iterate(.forwards, from: DoubleCoord(x: 50, y: 30)) { x, _, _ in
            xs.append(x)
            return xs.count < 5
        }
        XCTAssertEqual(xs, [50, 51, 52, 53, 54])
    }

    func testAnUnboundedBackwardWalkStepsTheOtherWay() {
        var xs: [Int] = []
        shallow.iterate(.backwards, from: DoubleCoord(x: 50, y: 30)) { x, _, _ in
            xs.append(x)
            return xs.count < 5
        }
        XCTAssertEqual(xs, [50, 49, 48, 47, 46])
    }

    func testAnUnboundedWalkThatIsRefusedImmediatelyVisitsOnePixel() {
        var count = 0
        shallow.iterate(.forwards, from: DoubleCoord(x: 50, y: 30)) { _, _, _ in
            count += 1
            return false
        }
        XCTAssertEqual(count, 1)
    }

    func testAnUnboundedVerticalWalkStepsY() {
        var ys: [Int] = []
        steep.iterate(.forwards, from: DoubleCoord(x: 14, y: 10)) { _, y, _ in
            ys.append(y)
            return ys.count < 4
        }
        XCTAssertEqual(ys, [10, 11, 12, 13])
    }

    /// Each visited pixel on the unbounded walk still has to be on the line.
    func testAnUnboundedWalkStaysOnTheLine() {
        let standard = shallow.standardLine
        var steps = 0
        shallow.iterate(.forwards, from: DoubleCoord(x: 50, y: 30)) { x, y, _ in
            XCTAssertEqual(Double(y), standard.y(forX: Double(x)), accuracy: 1.0)
            steps += 1
            return steps < 20
        }
        XCTAssertEqual(steps, 20)
    }

    // MARK: - the async mirrors

    /// `asyncIterate` is a hand-copied duplicate of the synchronous walk.  Since nothing
    /// ties the two together, the thing worth checking is that they still agree.
    func testAsyncBoundedWalkVisitsTheSamePixelsAsTheSyncOne() async {
        let line = Line(point1: DoubleCoord(x: 0, y: 10), point2: DoubleCoord(x: 100, y: 45))
        let from = DoubleCoord(x: 10, y: 13), to = DoubleCoord(x: 40, y: 24)

        var expected: [String] = []
        line.iterate(between: from, and: to) { x, y, _ in expected.append("\(x),\(y)") }

        let collector = Collector()
        await line.asyncIterate(between: from, and: to) { x, y, _ in
            await collector.add("\(x),\(y)")
        }
        let actual = await collector.items

        XCTAssertEqual(expected.count, 31)
        XCTAssertEqual(actual, expected)
    }

    func testAsyncBoundedWalkHonoursAdjacentPixelsLikeTheSyncOne() async {
        let line = Line(point1: DoubleCoord(x: 0, y: 200), point2: DoubleCoord(x: 100, y: 240))
        let from = DoubleCoord(x: 20, y: 208), to = DoubleCoord(x: 25, y: 210)

        var expected: [String] = []
        line.iterate(between: from, and: to, numberOfAdjecentPixels: 1) { x, y, _ in
            expected.append("\(x),\(y)")
        }

        let collector = Collector()
        await line.asyncIterate(between: from, and: to, numberOfAdjecentPixels: 1) { x, y, _ in
            await collector.add("\(x),\(y)")
        }
        let actual = await collector.items

        XCTAssertEqual(expected.count, 6 * 3)
        XCTAssertEqual(actual, expected)
    }

    func testAsyncUnboundedWalkStopsLikeTheSyncOne() async {
        let line = Line(point1: DoubleCoord(x: 0, y: 10), point2: DoubleCoord(x: 100, y: 30))
        let collector = Collector()
        await line.asyncIterate(.forwards, from: DoubleCoord(x: 50, y: 20)) { x, _, _ in
            await collector.add("\(x)")
            return await collector.count < 4
        }
        let actual = await collector.items
        XCTAssertEqual(actual, ["50", "51", "52", "53"])
    }

    /// The accumulating overload threads each closure result into the next call.
    func testTheAccumulatingAsyncWalkThreadsItsValueForward() async {
        let line = Line(point1: DoubleCoord(x: 0, y: 10), point2: DoubleCoord(x: 100, y: 30))
        let collector = Collector()
        await line.asyncIterate(between: DoubleCoord(x: 10, y: 12),
                                and: DoubleCoord(x: 15, y: 13)) { (_, _, _, previous: Int?) in
            let next = (previous ?? 0) + 1
            await collector.add("\(next)")
            return next
        }
        let actual = await collector.items
        XCTAssertEqual(actual, ["1", "2", "3", "4", "5", "6"])
    }

    private actor Collector {
        var items: [String] = []
        var count: Int { items.count }
        func add(_ item: String) { items.append(item) }
    }
}
