import XCTest
@testable import stard

/// The frame range `Processing.Start` asks for.
///
/// `end_index` used to be read as "to the end" when it was 0, so asking for just frame 0 — with
/// `force`, which resets every frame in the range — reset and re-ran the whole sequence.
final class ProcessingRangeTests: XCTestCase {

    func testAnEndOfZeroIsTheFirstFrameNotTheWholeSequence() {
        let r = ProcessingHandlers.frameRange(start: 0, end: 0)
        XCTAssertEqual(r.start, 0)
        XCTAssertEqual(r.end, 0)
    }

    func testANegativeEndMeansToTheEndOfTheSequence() {
        XCTAssertNil(ProcessingHandlers.frameRange(start: 0, end: -1).end)
        XCTAssertNil(ProcessingHandlers.frameRange(start: 5, end: -1).end)
    }

    func testAnExplicitRangeIsKeptInclusive() {
        let r = ProcessingHandlers.frameRange(start: 3, end: 7)
        XCTAssertEqual(r.start, 3)
        XCTAssertEqual(r.end, 7)
    }

    func testASingleLaterFrameIsThatFrame() {
        let r = ProcessingHandlers.frameRange(start: 4, end: 4)
        XCTAssertEqual(r.start, 4)
        XCTAssertEqual(r.end, 4)
    }

    func testANegativeStartIsClampedToTheFirstFrame() {
        XCTAssertEqual(ProcessingHandlers.frameRange(start: -3, end: 2).start, 0)
    }
}
