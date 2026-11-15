import XCTest
import AVFoundation
import SwiftUI
import Observation
import StarCore
import StarCppBridge
// The app target is named `Star`, not `star` — the lowercase name belongs to the .xcodeproj
// and to this test target.  TEST_HOST points at Star.app, so this is what links.
@testable import Star




// Which frames a painted reference horizon leaves stale, and which ones stay stale after a run
// over part of the sequence has taken some of them on, is `HorizonRefinementPlan` in StarCore now,
// tested there (HorizonRefinementPlanTests): the daemon the Kotlin client drives keeps the same
// record by the same rules.

/// `processFrames` takes a start and an optional end index from its callers and then
/// subscripts `frames` with everything between them.  Nothing on the way in checks that
/// those indices name frames that exist, and the re-process panel's "process the next N
/// frames" button routinely hands it indices that do not: it passes
/// `currentIndex + numberOfFramesToProcess - 1`, and `numberOfFramesToProcess` is capped
/// against the length of the whole sequence rather than against what is left of it.
///
/// Pressing that button from anywhere but the first frame, with a large enough N, used to
/// take the app down with `Index out of range` (0.11.5, reported 2026-08-30).
///
/// `processingRange` is the clamp that now sits in front of that subscript.  It is checked
/// here rather than through `processFrames` itself because standing up an
/// `ImageSequenceViewModel` needs a `ViewModel` and a `ConfigManager` — see the note on
/// `SettingsWiringTests` above.
final class ProcessingRangeTests: XCTestCase {
    private func range(_ start: Int, _ end: Int?, of count: Int) -> ClosedRange<Int>? {
        ImageSequenceViewModel.processingRange(from: start, to: end, frameCount: count)
    }

    /// The crash: "process the next 20 frames" from frame 15 of a 20 frame sequence.
    func testAnEndPastTheLastFrameIsClampedToIt() {
        XCTAssertEqual(range(15, 34, of: 20), 15...19)
    }

    func testARangeInsideTheSequenceIsLeftAlone() {
        XCTAssertEqual(range(3, 7, of: 20), 3...7)
    }

    func testASingleFrameIsARange() {
        XCTAssertEqual(range(7, 7, of: 20), 7...7)
    }

    /// No end index means "to the end of the sequence".
    func testNoEndIndexRunsToTheLastFrame() {
        XCTAssertEqual(range(4, nil, of: 20), 4...19)
    }

    func testTheLastFrameAloneIsAValidRun() {
        XCTAssertEqual(range(19, nil, of: 20), 19...19)
    }

    /// A start index past the end has no frames to offer, clamped or not — the alternative
    /// would be silently processing the last frame instead of the ones asked for.
    func testAStartPastTheLastFrameIsNoRun() {
        XCTAssertNil(range(20, 25, of: 20))
        XCTAssertNil(range(20, nil, of: 20))
    }

    func testABackwardsRangeIsNoRun() {
        XCTAssertNil(range(10, 4, of: 20))
    }

    func testANegativeStartIsNoRun() {
        XCTAssertNil(range(-1, 5, of: 20))
    }

    /// A sequence nothing has been loaded into yet: the old code went on to read
    /// `frames[0]` regardless.
    func testAnEmptySequenceIsNoRun() {
        XCTAssertNil(range(0, nil, of: 0))
        XCTAssertNil(range(0, 0, of: 0))
    }
}
