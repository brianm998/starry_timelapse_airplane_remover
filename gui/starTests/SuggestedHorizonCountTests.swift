import XCTest
import AVFoundation
import SwiftUI
import Observation
import StarCore
import StarCppBridge
// The app target is named `Star`, not `star` — the lowercase name belongs to the .xcodeproj
// and to this test target.  TEST_HOST points at Star.app, so this is what links.
@testable import Star


/// The moving-video startup prompt suggests how many reference horizons to paint by hand.
/// It used to suggest 3 whatever the sequence length, which is too few for a long moving
/// sequence: 12 was measured to work well over 1450 frames.  The suggestion is now derived
/// from the length, and the numbers it lands on are what this pins down — together with the
/// bound the stepper beside it relies on, that the suggestion is always a value the stepper's
/// `1...total` range can actually hold.
///
/// The Kotlin client duplicates the formula (`suggestedMovingHorizonCount` in
/// `AppViewModel.kt`, checked by `StartupHorizonTest`); the expected values here and there
/// are deliberately the same.
@MainActor
final class SuggestedHorizonCountTests: XCTestCase {

    private func suggestion(_ total: Int) -> Int {
        ImageSequenceViewModel.suggestedMovingHorizonCount(total: total)
    }

    // MARK: - how it scales

    /// 12 over 1450 frames is the measured value the curve is anchored to.
    func testTheSuggestionMatchesTheMeasuredValueForA1450FrameSequence() {
        XCTAssertEqual(suggestion(1450), 12)
    }

    func testTheSuggestionGrowsWithTheSequenceLength() {
        XCTAssertEqual(suggestion(1000), 10)
        XCTAssertEqual(suggestion(2000), 14)
        XCTAssertEqual(suggestion(5000), 22)
    }

    /// Growth has to be sublinear: a fixed one-horizon-every-N-frames rate would ask for over
    /// forty hand-painted horizons at 5000 frames, which nobody would sit through.  Doubling
    /// the sequence must grow the suggestion, but by less than double.
    func testTheSuggestionGrowsMoreSlowlyThanTheSequence() {
        XCTAssertGreaterThan(suggestion(2900), suggestion(1450))
        XCTAssertLessThan(suggestion(2900), 2 * suggestion(1450))
    }

    // MARK: - the short end

    /// Nothing under about 120 frames should see a different suggestion than before, where
    /// the spacing is already tight enough.
    func testShortSequencesStillGetThree() {
        XCTAssertEqual(suggestion(50), 3)
        XCTAssertEqual(suggestion(122), 3)
        XCTAssertEqual(suggestion(123), 4)
    }

    // MARK: - the bound the stepper depends on

    func testTheSuggestionNeverExceedsTheSequence() {
        XCTAssertEqual(suggestion(1), 1)
        XCTAssertEqual(suggestion(2), 2)
    }

    /// `maxCount` floors at 1 even for an empty sequence, so the suggestion has to as well
    /// or the stepper would start outside its own range.
    func testAnEmptySequenceSuggestsOne() {
        XCTAssertEqual(suggestion(0), 1)
        XCTAssertEqual(suggestion(-5), 1)
    }

    func testTheSuggestionIsAlwaysInsideTheSteppersRange() {
        for total in 1...6000 {
            let n = suggestion(total)
            XCTAssertGreaterThanOrEqual(n, 1, "suggestion \(n) below 1 for \(total) frames")
            XCTAssertLessThanOrEqual(n, total, "suggestion \(n) above \(total) frames")
        }
    }

    /// A longer sequence must never ask for fewer horizons than a shorter one.
    func testTheSuggestionNeverDecreasesAsTheSequenceGrows() {
        var previous = 0
        for total in 1...6000 {
            let n = suggestion(total)
            XCTAssertGreaterThanOrEqual(n, previous, "suggestion dropped at \(total) frames")
            previous = n
        }
    }
}
