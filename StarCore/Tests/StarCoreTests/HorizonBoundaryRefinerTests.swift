import XCTest
import Foundation
@testable import StarCore

/// `HorizonBoundaryRefiner` on synthetic log-luminance images whose true horizon is known.
///
/// Each case pins one of the properties its documentation calls load-bearing: following a
/// tree to its tip, taking the topmost transition when something sky-like lies below it,
/// and staying inside the corridor whatever is misread above it.
final class HorizonBoundaryRefinerTests: XCTestCase {

    /// A log-luminance image from a per-pixel brightness rule (linear, 0...1).
    private func image(width: Int, height: Int,
                       _ brightness: (Int, Int) -> Double) -> [Float] {
        var lm = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                lm[y * width + x] = Float(log(brightness(x, y) + 1e-4))
            }
        }
        return lm
    }

    /// A sky with a gentle gradient, as a real one has, over a much darker ground.
    private let sky = { (y: Int) in 0.30 - 0.0003 * Double(y) }
    private let ground = 0.01

    func testAFlatHorizonIsFoundFromANearbyGuess() {
        let w = 200, h = 300
        let lm = image(width: w, height: h) { _, y in y < 200 ? self.sky(y) : self.ground }
        let line = HorizonBoundaryRefiner.refine(logLuminance: lm, width: w, height: h,
                                                 guess: [Int?](repeating: 188, count: w))
        for x in 0..<w {
            XCTAssertEqual(line[x], 200, accuracy: 1, "column \(x)")
        }
    }

    /// A conifer six columns wide and thirty rows tall standing on the ground: the line has to
    /// climb to its tip and come back down, because a tip called sky is smeared by the star
    /// alignment.
    func testATreeIsFollowedToItsTip() {
        let w = 200, h = 300
        let lm = image(width: w, height: h) { x, y in
            let tree = (90..<96).contains(x) && y >= 170
            return (y >= 200 || tree) ? self.ground : self.sky(y)
        }
        let line = HorizonBoundaryRefiner.refine(logLuminance: lm, width: w, height: h,
                                                 guess: [Int?](repeating: 200, count: w))
        for x in 90..<96 {
            XCTAssertEqual(line[x], 170, accuracy: 1, "tree column \(x)")
        }
        XCTAssertEqual(line[40], 200, accuracy: 1)
        XCTAssertEqual(line[160], 200, accuracy: 1)
    }

    /// A lake: a dark band of distant mountains, then water as bright as the sky, then the
    /// near shore.  The horizon is the top of the mountains — the first transition from sky
    /// to ground — not the bottom of the water, however much sky-like area that would put
    /// above the line.
    func testWaterBelowTheMountainsDoesNotPullTheLineDown() {
        let w = 200, h = 400
        let lm = image(width: w, height: h) { _, y in
            switch y {
            case ..<200: return self.sky(y)
            case 200..<230: return self.ground          // mountains
            case 230..<260: return 0.25                  // water, mirroring the sky
            default: return self.ground                  // near shore
            }
        }
        let line = HorizonBoundaryRefiner.refine(logLuminance: lm, width: w, height: h,
                                                 guess: [Int?](repeating: 206, count: w))
        for x in stride(from: 0, to: w, by: 10) {
            XCTAssertEqual(line[x], 200, accuracy: 1, "column \(x)")
        }
    }

    /// A dark patch high in the sky — a vignetted corner, a cloud — is outside the corridor
    /// around the guess and must not drag the line up to it.
    func testAPatchMisreadAsGroundAboveTheCorridorIsIgnored() {
        let w = 200, h = 300
        let lm = image(width: w, height: h) { x, y in
            if x < 40 && y < 60 { return self.ground }  // the dark corner
            return y < 200 ? self.sky(y) : self.ground
        }
        let line = HorizonBoundaryRefiner.refine(logLuminance: lm, width: w, height: h,
                                                 guess: [Int?](repeating: 196, count: w))
        for x in 0..<40 {
            XCTAssertEqual(line[x], 200, accuracy: 1, "corner column \(x)")
        }
    }

    /// Columns with no guess at all borrow the nearest defined one rather than collapsing to a
    /// default.
    func testMissingGuessesAreFilledFromTheNearestColumn() {
        let filled = HorizonBoundaryRefiner.filledGuess([nil, 10, nil, nil, 40, nil], height: 50)
        XCTAssertEqual(filled, [10, 10, 10, 40, 40, 40])
        XCTAssertEqual(HorizonBoundaryRefiner.filledGuess([nil, nil], height: 50), [50, 50],
                       "with nothing to go on, every column is all sky")
    }

    // MARK: - the dynamic programme

    /// Two flat valleys of cost, the second ten rows lower.  A cheap jump takes the line from one
    /// to the other in a single column; an expensive one keeps it where it started.
    func testTheCheapestPathJumpsWhenTheJumpIsCheaperThanStaying() {
        let w = 10, rows = 20
        var cost = [Double](repeating: 10, count: w * rows)
        for x in 0..<w { cost[x * rows + (x < 5 ? 5 : 15)] = 0 }

        let jumping = HorizonBoundaryRefiner.cheapestPath(cost: cost, width: w, rows: rows,
                                                          smoothness: 1, jumpCost: 3)
        XCTAssertEqual(jumping, [5, 5, 5, 5, 5, 15, 15, 15, 15, 15])

        // Staying costs 10 per column for five columns; a jump that costs more than that sum
        // is never taken.
        let staying = HorizonBoundaryRefiner.cheapestPath(cost: cost, width: w, rows: rows,
                                                          smoothness: 100, jumpCost: 100)
        XCTAssertEqual(Set(staying).count, 1, "an unaffordable jump must not be taken: \(staying)")
    }

    func testTheSmoothnessCostIsLinearInTheStepBelowTheJumpCap() {
        // A valley that moves down one row per column is followed exactly when a one-row step
        // costs less than leaving the valley.
        let w = 8, rows = 12
        var cost = [Double](repeating: 5, count: w * rows)
        for x in 0..<w { cost[x * rows + 2 + x] = 0 }
        let line = HorizonBoundaryRefiner.cheapestPath(cost: cost, width: w, rows: rows,
                                                       smoothness: 1, jumpCost: 50)
        XCTAssertEqual(line, Array(2..<(2 + w)))
    }

    // MARK: - small helpers

    func testInterpolationFillsGapsAndHoldsTheEnds() {
        let filled = HorizonBoundaryRefiner.interpolated([nil, 2, nil, nil, 8, nil])
        XCTAssertEqual(filled, [2, 2, 4, 6, 8, 8])
        XCTAssertEqual(HorizonBoundaryRefiner.interpolated([nil, nil]), [0, 0])
    }

    func testTheRunningMedianRemovesALoneOutlier() {
        let values: [Double] = [1, 1, 1, 9, 1, 1, 1]
        XCTAssertEqual(HorizonBoundaryRefiner.medianFiltered(values, window: 3),
                       [1, 1, 1, 1, 1, 1, 1])
    }

    func testNthElementMatchesSorting() {
        var values: [Float] = [5, 3, 9, 1, 7, 2, 8]
        let sorted = values.sorted()
        for k in values.indices {
            var copy = values
            XCTAssertEqual(HorizonBoundaryRefiner.nthElement(&copy, k), sorted[k])
        }
        var empty: [Float] = []
        XCTAssertNil(HorizonBoundaryRefiner.median(&empty))
        XCTAssertEqual(HorizonBoundaryRefiner.median(&values), 5)
    }
}
