import XCTest
import StarCppBridge
@testable import StarCore

/// `BunchCalculator` flood fills a blob's pixels into connected clusters, and
/// `calculateBunchData` reduces that to the (count, median, max) triple the decision tree
/// consumes as an outlier feature.  A blob made of one solid streak and a blob made of
/// scattered specks have very different bunch counts, which is what makes the feature useful —
/// so the clustering has to be right.
final class BunchCalculatorTests: XCTestCase {

    private func pixels(_ coords: [(Int, Int)]) -> Set<SortablePixel> {
        Set(coords.map { SortablePixel(x: $0.0, y: $0.1, value: .sixteenBit(1000)) })
    }

    /// The bounds have to enclose every pixel: `BunchCalculator` indexes a flat array by
    /// position relative to `bounds.min`, so a pixel outside them would run off the end.
    private func bounds(_ coords: [(Int, Int)]) -> BoundingBox {
        BoundingBox(min: Coord(x: coords.map(\.0).min()!, y: coords.map(\.1).min()!),
                    max: Coord(x: coords.map(\.0).max()!, y: coords.map(\.1).max()!))
    }

    private func bunches(_ coords: [(Int, Int)], maxPixelDistance: Int) -> [Set<SortablePixel>] {
        BunchCalculator(from: pixels(coords),
                        with: bounds(coords),
                        maxPixelDistance: maxPixelDistance).calculateBunches()
    }

    // MARK: - degenerate inputs

    func testNoPixelsMeansNoBunches() {
        let calculator = BunchCalculator(from: [],
                                         with: BoundingBox(min: Coord(x: 0, y: 0),
                                                           max: Coord(x: 9, y: 9)),
                                         maxPixelDistance: 1)
        XCTAssertTrue(calculator.calculateBunches().isEmpty)
    }

    func testASinglePixelIsOneBunchOfOne() {
        let result = bunches([(5, 5)], maxPixelDistance: 1)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.count, 1)
    }

    // MARK: - connectivity

    /// A solid horizontal run is one bunch — the shape an airplane trail actually has.
    func testAContiguousRunIsASingleBunch() {
        let run = (0..<10).map { ($0, 0) }
        let result = bunches(run, maxPixelDistance: 1)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.count, 10)
    }

    func testAContiguousDiagonalIsASingleBunch() {
        let diagonal = (0..<10).map { ($0, $0) }
        let result = bunches(diagonal, maxPixelDistance: 1)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.count, 10)
    }

    func testASolidBlockIsASingleBunch() {
        var block: [(Int, Int)] = []
        for x in 0..<5 { for y in 0..<5 { block.append((x, y)) } }
        let result = bunches(block, maxPixelDistance: 1)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.count, 25)
    }

    /// Two runs far enough apart stay separate, which is what gives a speckled blob a high
    /// bunch count.
    func testTwoDistantClustersAreTwoBunches() {
        let coords = (0..<5).map { ($0, 0) } + (0..<5).map { ($0 + 50, 0) }
        let result = bunches(coords, maxPixelDistance: 1)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result.map(\.count).sorted(), [5, 5])
    }

    func testEveryPixelEndsUpInExactlyOneBunch() {
        let coords = (0..<6).map { ($0, 0) } + (0..<6).map { ($0 + 40, 20) } + [(80, 80)]
        let result = bunches(coords, maxPixelDistance: 1)

        XCTAssertEqual(result.reduce(0) { $0 + $1.count }, coords.count,
                       "the bunches do not account for every pixel")
        var seen: Set<SortablePixel> = []
        for bunch in result {
            XCTAssertTrue(seen.isDisjoint(with: bunch), "a pixel landed in two bunches")
            seen.formUnion(bunch)
        }
        XCTAssertEqual(seen.count, coords.count)
    }

    func testScatteredPixelsEachFormTheirOwnBunch() {
        let scattered = (0..<6).map { ($0 * 20, $0 * 20) }
        let result = bunches(scattered, maxPixelDistance: 1)
        XCTAssertEqual(result.count, 6)
        XCTAssertEqual(Set(result.map(\.count)), [1])
    }

    // MARK: - maxPixelDistance

    /// The neighbourhood `calculateBunches` scans is not symmetric.  For a pixel at local x and
    /// a tolerance of `d` it scans `(x - d - 1) ..< (x + d + 1)`, so it reaches `d + 1` pixels
    /// backwards but only `d` forwards.  Combined with the `handledPixels` skip and `Set`'s
    /// unspecified iteration order, a gap of exactly `d + 1` merges or not depending on which
    /// end the flood fill happens to start from — the result is genuinely non-deterministic
    /// between runs.
    ///
    /// Every gap in these tests is therefore chosen to be unambiguous: `gap <= d` always merges,
    /// `gap > d + 1` never does.  Nothing here sits on `gap == d + 1`.
    ///
    /// Raising the tolerance bridges gaps, which is the knob's whole purpose.
    func testRaisingTheToleranceMergesClustersAcrossAGap() {
        // two runs with a three pixel gap between them (x 2 to x 5)
        let coords = [(0, 0), (1, 0), (2, 0), (5, 0), (6, 0), (7, 0)]

        XCTAssertEqual(bunches(coords, maxPixelDistance: 1).count, 2,
                       "a gap of 3 is past the reach of a tolerance of 1")
        XCTAssertEqual(bunches(coords, maxPixelDistance: 3).count, 1,
                       "a tolerance of 3 reaches a gap of 3 in either direction")
    }

    func testTheBunchCountFallsAsToleranceRises() {
        // three clusters, separated by gaps of 5 (x 1 to 6) and 11 (x 7 to 18)
        let coords = [(0, 0), (1, 0), (6, 0), (7, 0), (18, 0), (19, 0)]

        XCTAssertEqual(bunches(coords, maxPixelDistance: 1).count, 3,
                       "both gaps are out of reach at a tolerance of 1")
        XCTAssertEqual(bunches(coords, maxPixelDistance: 5).count, 2,
                       "a tolerance of 5 closes the first gap but not the second")
        XCTAssertEqual(bunches(coords, maxPixelDistance: 11).count, 1,
                       "a tolerance of 11 closes both")
    }

    /// However the clusters end up divided, the tolerance can only ever merge — so the count is
    /// non-increasing across the sweep, and a large enough tolerance collapses everything.
    func testTheBunchCountNeverRisesAsToleranceRises() {
        let coords = [(0, 0), (1, 0), (6, 0), (7, 0), (18, 0), (19, 0)]
        var previous = Int.max
        for tolerance in 1...25 {
            let count = bunches(coords, maxPixelDistance: tolerance).count
            XCTAssertLessThanOrEqual(count, previous,
                                     "tolerance \(tolerance) produced more bunches than \(tolerance - 1)")
            previous = count
        }
        XCTAssertEqual(previous, 1, "a large enough tolerance should merge everything")
    }

    /// `maxBunchDistance` is the shared constant the rest of the code passes in, so it needs to
    /// be large enough to hold a diagonal line together.
    func testTheSharedBunchDistanceHoldsADiagonalTogether() {
        XCTAssertEqual(maxBunchDistance, 2)
        let diagonal = (0..<12).map { ($0 * 2, $0 * 2) }   // 2 pixel steps
        XCTAssertEqual(bunches(diagonal, maxPixelDistance: maxBunchDistance).count, 1)
    }

    // MARK: - calculateBunchData

    /// The triple is (number of bunches, median bunch size, largest bunch size).
    func testBunchDataReportsCountMedianAndMaximum() {
        // three clusters of 1, 3 and 5 pixels, far apart
        let coords = [(0, 0)]
                   + (0..<3).map { ($0 + 30, 0) }
                   + (0..<5).map { ($0 + 60, 0) }
        let group = OutlierGroup(id: 1, size: UInt(coords.count), brightness: 1000,
                                 bounds: bounds(coords), frameIndex: 0, pixels: [],
                                 pixelSet: pixels(coords))

        let (count, median, largest) = calculateBunchData(from: group, maxPixelDistance: 1)
        XCTAssertEqual(count, 3)
        XCTAssertEqual(largest, 5)
        // sizes sort to [1, 3, 5] and the median index is 3/2 == 1
        XCTAssertEqual(median, 3)
    }

    func testASolidStreakIsOneBunchWhoseMedianIsItsSize() {
        let coords = (0..<20).map { ($0, 0) }
        let group = OutlierGroup(id: 1, size: 20, brightness: 1000,
                                 bounds: bounds(coords), frameIndex: 0, pixels: [],
                                 pixelSet: pixels(coords))

        let (count, median, largest) = calculateBunchData(from: group, maxPixelDistance: 1)
        XCTAssertEqual(count, 1)
        XCTAssertEqual(median, 20)
        XCTAssertEqual(largest, 20)
    }

    /// The feature only earns its place if a streak and a scatter of the same pixel count come
    /// out differently.
    func testAStreakAndAScatterOfEqualSizeAreDistinguishable() {
        let streakCoords = (0..<10).map { ($0, 0) }
        let scatterCoords = (0..<10).map { ($0 * 20, 0) }

        func data(_ coords: [(Int, Int)]) -> (Int, Int, Int) {
            let group = OutlierGroup(id: 1, size: UInt(coords.count), brightness: 1000,
                                     bounds: bounds(coords), frameIndex: 0, pixels: [],
                                     pixelSet: pixels(coords))
            return calculateBunchData(from: group, maxPixelDistance: 1)
        }

        let streak = data(streakCoords), scatter = data(scatterCoords)
        XCTAssertEqual(streak.0, 1)
        XCTAssertEqual(scatter.0, 10)
        XCTAssertGreaterThan(streak.2, scatter.2)
    }

    func testTheLargestBunchIsNeverSmallerThanTheMedian() {
        let coords = [(0, 0), (1, 0), (2, 0), (3, 0)]
                   + [(40, 0), (41, 0)]
                   + [(80, 0)]
        let group = OutlierGroup(id: 1, size: UInt(coords.count), brightness: 1000,
                                     bounds: bounds(coords), frameIndex: 0, pixels: [],
                                     pixelSet: pixels(coords))
        let (count, median, largest) = calculateBunchData(from: group, maxPixelDistance: 1)
        XCTAssertEqual(count, 3)
        XCTAssertGreaterThanOrEqual(largest, median)
        XCTAssertEqual(largest, 4)
    }
}
