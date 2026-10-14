import XCTest
import StarCore
import StarCppBridge
import StarDaemonMessages
@testable import stard

/// The outlier window's Hough-line panel: the lines proposed for a group, choosing one, and the finder's arguments.
final class LineHandlersTests: XCTestCase {

    /// A streak running corner to corner of a 60 x 60 box at (200, 100), two pixels thick, on a 1000 x 500 frame.
    private func diagonalGroup() -> OutlierGroup {
        let x0 = 200, y0 = 100, n = 60
        let bounds = BoundingBox(min: Coord(x: x0, y: y0), max: Coord(x: x0 + n - 1, y: y0 + n - 1))
        var pixelSet: Set<SortablePixel> = []
        var pixels = [UInt16](repeating: 0, count: n * n)
        for i in 0..<n {
            for d in 0...1 where i + d < n {
                pixelSet.insert(SortablePixel(x: x0 + i + d, y: y0 + i, value: .sixteenBit(1000)))
                pixels[i * n + i + d] = 1000
            }
        }
        return OutlierGroup(id: 9, size: UInt(pixelSet.count), brightness: 1000, bounds: bounds, frameIndex: 0,
                            imageWidth: 1000, imageHeight: 500, pixels: pixels, pixelSet: pixelSet)
    }

    func testTheCandidatesAreTheFindersLinesBestFitFirst() async {
        let found = await LineHandlers.candidates(for: diagonalGroup())
        XCTAssertFalse(found.isEmpty)
        // the box's two diagonals are always offered, whatever the finder finds
        XCTAssertTrue(found.contains { $0.border == -1 })
        XCTAssertTrue(found.contains { $0.border == -2 })
        XCTAssertEqual(found.map(\.intensityScore), found.map(\.intensityScore).sorted(by: >), "best fit first")
        XCTAssertTrue(found.allSatisfy { $0.intensityScore.isFinite && $0.intensityScore >= 0 && $0.pixelScore.isFinite })
        XCTAssertGreaterThan(found[0].intensityScore, 0, "something must fit a streak")
    }

    func testChoosingALineMakesItTheGroupsLine() async {
        let group = diagonalGroup()
        let found = await LineHandlers.candidates(for: group)
        let other = found.first { $0.border == -2 }!
        let after = await LineHandlers.choose(other, for: group)
        XCTAssertEqual(after.line.theta, other.line.theta)
        XCTAssertEqual(after.line.rho, other.line.rho)
        let line = await group.line()
        XCTAssertEqual(line?.theta, other.line.theta, "a group must not work its own line out again over the one chosen")
        XCTAssertEqual(line?.rho, other.line.rho)
    }

    func testChoosingALineBeforeTheGroupHasWorkedOutItsOwnKeepsTheChosenOne() async {
        let group = diagonalGroup()     // its own line has not been asked for yet
        var chosen = Star_V1_LineCandidate()
        chosen.line = Mapping.protoLine(Line(theta: 12, rho: 3.5, votes: 7))
        chosen.intensityScore = 1; chosen.pixelScore = 2; chosen.border = 4000
        _ = await LineHandlers.choose(chosen, for: group)
        let line = await group.line()
        XCTAssertEqual(line?.theta, 12)
        XCTAssertEqual(line?.rho, 3.5)
        XCTAssertEqual(line?.votes, 7)
    }

    func testTheArgumentsAreListedWithTheirNamesAndDescriptions() {
        let listed = LineHandlers.args(HoughLineFinder.Args())
        XCTAssertEqual(listed.args.map(\.name), ["imageDataBorderSize", "maxLineConstant"])
        XCTAssertEqual(listed.args.map(\.value), [4000, 500])
        XCTAssertTrue(listed.args.allSatisfy { $0.isInteger && !$0.description_p.isEmpty })
    }

    func testAnArgumentIsSetByName() {
        let args = HoughLineFinder.Args()
        let updated = LineHandlers.updated(args, name: "maxLineConstant", value: 120)
        XCTAssertEqual(updated?.value(for: .maxLineConstant), 120)
        XCTAssertEqual(updated?.value(for: .imageDataBorderSize), 4000, "the other argument is left alone")
    }

    func testAWholeNumberArgumentIsRounded() {
        XCTAssertEqual(LineHandlers.updated(HoughLineFinder.Args(), name: "maxLineConstant", value: 12.6)?.value(for: .maxLineConstant), 13)
    }

    func testAnUnknownOrUnusableArgumentIsRefused() {
        XCTAssertNil(LineHandlers.updated(HoughLineFinder.Args(), name: "nope", value: 1))
        XCTAssertNil(LineHandlers.updated(HoughLineFinder.Args(), name: "maxLineConstant", value: .nan))
        XCTAssertNil(LineHandlers.updated(HoughLineFinder.Args(), name: "maxLineConstant", value: .infinity))
    }
}
