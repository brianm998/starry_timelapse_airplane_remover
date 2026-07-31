import XCTest
import StarCppBridge
@testable import StarCore

/// `HoughLineFinder` turns a blob's pixels into candidate lines.  It is what decides whether a blob
/// looks like an airplane trail — a straight line of pixels — or like something else, and its output
/// feeds `lineLength`, `lineIntensityScore` and `linePixelScore`, all decision-tree features.
///
/// There are two of them.  `HoughLineFinder` is the plain KHT wrapper, and its `lineData` really can
/// be empty — the KHT returned nothing for a clean twenty pixel streak in these tests, which is
/// presumably why the other one exists.  `CombinedHoughLineFinder` runs one or two plain finders and
/// then appends two lines through opposite corners of the bounding box "as a last ditch ... this
/// might be better than the line we get from KHT :(", so its `lineData` is never empty.
///
/// Worth knowing: `HoughLineMatrixBlobConnector` builds the *plain* one —
/// `/*Combined*/HoughLineFinder(...)`, with `Combined` commented out — so production takes the path
/// that can come back with nothing.  It handles that safely (it sorts and iterates, so an empty list
/// just does no work), but it means the corner fallback is currently unused there.
final class HoughLineFinderTests: XCTestCase {

    private func args(maxLines: Int = 20, border: Int = 0) -> HoughLineFinder.Args {
        HoughLineFinder.Args(imageDataBorderSize: border, maxLineConstant: maxLines)
    }

    private func pixels(_ coords: [(Int, Int)], value: UInt16 = 30000) -> [SortablePixel] {
        coords.map { SortablePixel(x: $0.0, y: $0.1, value: .sixteenBit(value)) }
    }

    private func bounds(_ coords: [(Int, Int)]) -> BoundingBox {
        BoundingBox(min: Coord(x: coords.map(\.0).min()!, y: coords.map(\.1).min()!),
                    max: Coord(x: coords.map(\.0).max()!, y: coords.map(\.1).max()!))
    }

    /// The combined finder, which is the one with the corner fallback.
    private func finder(_ coords: [(Int, Int)],
                        maxLines: Int = 20) -> CombinedHoughLineFinder
    {
        CombinedHoughLineFinder(pixels: pixels(coords),
                                bounds: bounds(coords),
                                args: args(maxLines: maxLines),
                                frameIndex: 0)
    }

    /// The plain KHT wrapper, which is what production actually builds.
    private func plainFinder(_ coords: [(Int, Int)],
                             maxLines: Int = 20) -> HoughLineFinder
    {
        HoughLineFinder(pixels: pixels(coords),
                        bounds: bounds(coords),
                        args: args(maxLines: maxLines),
                        frameIndex: 0,
                        imageDataBorderSize: 0)
    }

    // MARK: - there is always something to work with

    /// `lineData` appends two lines through opposite corners of the bounding box whatever the KHT
    /// returned, so callers never have to handle an empty list.  `HoughLineMatrixBlobConnector`
    /// sorts and slices it without checking, so an empty list there would be a different kind of
    /// problem.
    func testAHorizontalRunProducesAtLeastOneLine() {
        let run = (0..<20).map { ($0, 5) }
        XCTAssertFalse(finder(run).lineData.isEmpty)
    }

    func testASinglePixelStillProducesTheFallbackLines() {
        let single = finder([(5, 5)])
        XCTAssertFalse(single.lineData.isEmpty,
                       "the corner fallback should apply even to one pixel")
    }

    /// A blob with no pixels at all is degenerate, but the fallback is built from the bounds rather
    /// than the pixels, so it still answers.
    func testNoPixelsStillProducesTheFallbackLines() {
        let empty = CombinedHoughLineFinder(pixels: [],
                                            bounds: BoundingBox(min: Coord(x: 0, y: 0),
                                                                max: Coord(x: 10, y: 10)),
                                            args: args(),
                                            frameIndex: 0)
        XCTAssertFalse(empty.lineData.isEmpty)
    }

    /// The plain finder is the one production builds, and it does come back empty for inputs the KHT
    /// makes nothing of.  Pinned so the difference between the two is on the record.
    func testThePlainFinderCanComeBackWithNothing() {
        let run = (0..<20).map { ($0, 5) }
        XCTAssertTrue(plainFinder(run).lineData.isEmpty,
                      "if the KHT now finds this streak, the combined finder's fallback matters less")
    }

    /// `line` is the convenience that picks the best-scoring candidate.  On the combined finder it is
    /// therefore never nil.
    func testTheCombinedFinderAlwaysHasABestLine() {
        XCTAssertNotNil(finder((0..<20).map { ($0, 5) }).line)
        XCTAssertNotNil(finder([(5, 5)]).line)
    }

    /// Every line it reports has to be usable: finite theta and rho, or the geometry downstream
    /// produces NaNs.
    func testEveryReportedLineIsFinite() {
        for coords in [(0..<20).map { ($0, 5) },
                       (0..<20).map { (5, $0) },
                       (0..<20).map { ($0, $0) },
                       [(3, 3), (10, 20), (25, 7)]] {
            for info in finder(coords).lineData {
                XCTAssertFalse(info.line.theta.isNaN, "theta was NaN")
                XCTAssertFalse(info.line.rho.isNaN, "rho was NaN")
                XCTAssertTrue(info.line.theta.isFinite)
                XCTAssertTrue(info.line.rho.isFinite)
                XCTAssertFalse(info.intensityScore.isNaN)
                XCTAssertFalse(info.pixelScore.isNaN)
            }
        }
    }

    /// The scores are what the caller sorts on, so they have to be real numbers in a sane range.
    func testTheScoresAreFiniteAndNotNegative() {
        let run = (0..<30).map { ($0, 10) }
        for info in finder(run).lineData {
            XCTAssertTrue(info.intensityScore.isFinite)
            XCTAssertTrue(info.pixelScore.isFinite)
            XCTAssertGreaterThanOrEqual(info.intensityScore, 0)
            XCTAssertGreaterThanOrEqual(info.pixelScore, 0)
        }
    }

    /// Each `LineInfo` carries its own identity, which is how the gui's blob views key their rows.
    func testEachLineInfoHasItsOwnIdentity() {
        let lines = finder((0..<20).map { ($0, 5) }).lineData
        XCTAssertEqual(Set(lines.map(\.id)).count, lines.count, "two LineInfos share an id")
    }

    // MARK: - the line actually fits the pixels

    /// The point of the finder: for a blob that really is a straight line, the best-scoring line it
    /// returns should pass close to the blob's own pixels.  Scored rather than exact, since the KHT
    /// quantises theta and rho.
    func testTheBestLineForAStraightRunPassesThroughIt() {
        let run = (0..<30).map { ($0, 12) }             // a horizontal streak
        let found = finder(run)

        var best = found.lineData
        best.sort { $0.intensityScore > $1.intensityScore }
        guard let top = best.first else { return XCTFail("no lines found") }

        let standard = found.originZeroLine(from: top.line).standardLine
        var worst = 0.0
        for (x, y) in run {
            worst = max(worst, standard.distanceTo(x: x, y: y))
        }
        XCTAssertLessThan(worst, 3.0,
                          "the best line sat \(worst) pixels away from a straight streak")
    }

    func testTheBestLineForAVerticalRunPassesThroughIt() {
        let run = (0..<30).map { (12, $0) }
        let found = finder(run)

        var best = found.lineData
        best.sort { $0.intensityScore > $1.intensityScore }
        guard let top = best.first else { return XCTFail("no lines found") }

        let standard = found.originZeroLine(from: top.line).standardLine
        var worst = 0.0
        for (x, y) in run { worst = max(worst, standard.distanceTo(x: x, y: y)) }
        XCTAssertLessThan(worst, 3.0, "the best line sat \(worst) pixels away")
    }

    func testTheBestLineForADiagonalRunPassesThroughIt() {
        let run = (0..<30).map { ($0, $0) }
        let found = finder(run)

        var best = found.lineData
        best.sort { $0.intensityScore > $1.intensityScore }
        guard let top = best.first else { return XCTFail("no lines found") }

        let standard = found.originZeroLine(from: top.line).standardLine
        var worst = 0.0
        for (x, y) in run { worst = max(worst, standard.distanceTo(x: x, y: y)) }
        XCTAssertLessThan(worst, 3.0, "the best line sat \(worst) pixels away")
    }

    /// `originZeroLine` converts a line found in the blob's own bounds-relative space into frame
    /// coordinates.  A blob away from the origin has to come back describing where it really is.
    func testOriginZeroLineMovesALineIntoFrameCoordinates() {
        // the same streak, once at the origin and once offset well into the frame
        let atOrigin = (0..<20).map { ($0, 5) }
        let offset = atOrigin.map { ($0.0 + 500, $0.1 + 300) }

        let foundOffset = finder(offset)
        var best = foundOffset.lineData
        best.sort { $0.intensityScore > $1.intensityScore }
        guard let top = best.first else { return XCTFail("no lines found") }

        let standard = foundOffset.originZeroLine(from: top.line).standardLine
        var worst = 0.0
        for (x, y) in offset { worst = max(worst, standard.distanceTo(x: x, y: y)) }
        XCTAssertLessThan(worst, 3.0,
                          "the offset streak's line should describe its real position, was "
                          + "\(worst) pixels off")
    }

    // MARK: - the line count cap

    /// The cap is what keeps the connector's per-line work bounded on a messy frame.
    func testTheFinderRespectsItsLineCap() {
        // a scatter, which gives the KHT plenty of candidates
        var scatter: [(Int, Int)] = []
        for i in 0..<40 { scatter.append((i * 3 % 61, i * 7 % 59)) }

        for cap in [1, 3, 10] {
            let lines = HoughLineFinder(pixels: pixels(scatter),
                                        bounds: bounds(scatter),
                                        args: args(maxLines: cap),
                                        frameIndex: 0).lineData
            // the two corner fallbacks are appended after the cap is applied to the KHT output,
            // so the total can exceed the cap by those
            XCTAssertLessThanOrEqual(lines.count, cap + 2,
                                     "cap \(cap) produced \(lines.count) lines")
        }
    }

    // MARK: - determinism

    /// The scores feed decision-tree features, so the same pixels have to give the same lines every
    /// time.
    func testTheSamePixelsGiveTheSameLinesEveryTime() {
        let run = (0..<25).map { ($0, $0 / 2 + 3) }

        func fingerprint() -> [String] {
            finder(run).lineData
                .map { String(format: "%.6f/%.6f/%.6f", $0.line.theta, $0.line.rho, $0.intensityScore) }
                .sorted()
        }

        let first = fingerprint()
        XCTAssertFalse(first.isEmpty)
        for run in 1...5 {
            XCTAssertEqual(fingerprint(), first, "run \(run) found different lines")
        }
    }

    /// A blob's line should not depend on where in the frame the blob sits — the same shape offset
    /// by a thousand pixels is the same shape.  Compared through the fit rather than the raw theta
    /// and rho, which are frame-relative by construction.
    func testTheFitQualityDoesNotDependOnWhereTheBlobSits() {
        let shape = (0..<20).map { ($0, $0 / 3) }

        func worstFit(offsetBy dx: Int, _ dy: Int) -> Double {
            let moved = shape.map { ($0.0 + dx, $0.1 + dy) }
            let found = finder(moved)
            var best = found.lineData
            best.sort { $0.intensityScore > $1.intensityScore }
            guard let top = best.first else { return .infinity }
            let standard = found.originZeroLine(from: top.line).standardLine
            return moved.reduce(0.0) { max($0, standard.distanceTo(x: $1.0, y: $1.1)) }
        }

        let atOrigin = worstFit(offsetBy: 0, 0)
        let farAway = worstFit(offsetBy: 1000, 700)

        XCTAssertLessThan(atOrigin, 3.0)
        XCTAssertLessThan(farAway, 3.0,
                          "the same shape fitted worse at [1000, 700]: \(farAway) vs \(atOrigin)")
    }
}
