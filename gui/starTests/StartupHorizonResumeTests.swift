import XCTest
import AVFoundation
import SwiftUI
import Observation
import StarCore
import StarCppBridge
// The app target is named `Star`, not `star` — the lowercase name belongs to the .xcodeproj
// and to this test target.  TEST_HOST points at Star.app, so this is what links.
@testable import Star


/// What the user picks in that prompt is remembered, so the next sequence starts from their
/// taste rather than star's.  It is remembered as a multiple of what star suggested, not as a
/// count: 12 references over 1450 frames means "one about every 120 frames", and storing the
/// 12 would ask for the same 12 on a 200 frame sequence.
///
/// The arithmetic lives in statics precisely so it can be checked without standing up a live
/// view model.  The Kotlin client duplicates it (`preferredMovingHorizonCount` /
/// `movingHorizonCountMultiplier` in `AppViewModel.kt`) and shares the preferences file, so the
/// expected values here and in `StartupHorizonTest` are deliberately the same.
/// A sequence whose hand-painted horizon selection was interrupted has to come back to it.
///
/// Before this, re-opening one went straight to the progress panel and then to processing —
/// which ran the frames the user never got to with the automatic horizon detection they had
/// already declined, and said nothing about it.  The record lives in `Config` so it survives
/// the session; this is the decision made from it.
@MainActor
final class StartupHorizonResumeTests: XCTestCase {

    private func resume(_ indices: [Int], _ position: Int, frames: Int = 100) -> Int? {
        ImageSequenceViewModel.startupHorizonResumeFrame(indices: indices,
                                                         position: position,
                                                         frameCount: frames)
    }

    // MARK: - what resumes

    /// The case the whole thing is for: stopped after painting two of five.
    func testAnUnfinishedSelectionResumesOnTheFrameItStoppedAt() {
        XCTAssertEqual(resume([0, 25, 50, 75, 99], 2), 50)
    }

    func testASelectionStoppedBeforeItsFirstFrameResumesOnThatFrame() {
        XCTAssertEqual(resume([0, 25, 50, 75, 99], 0), 0)
    }

    func testTheLastFrameOfASelectionStillResumes() {
        XCTAssertEqual(resume([0, 25, 50, 75, 99], 4), 99)
    }

    /// The static flow paints one frame, and records it the same way so that it resumes by
    /// the same route.
    func testASingleFrameSelectionResumes() {
        XCTAssertEqual(resume([42], 0), 42)
    }

    // MARK: - what does not

    /// The overwhelmingly common case: the user never asked to paint anything, or asked and
    /// finished.  Both leave the list empty, and a re-open must go to the progress panel.
    func testNoRecordedSelectionDoesNotResume() {
        XCTAssertNil(resume([], 0))
        XCTAssertNil(resume([], 3))
    }

    /// A finished selection clears the list, so a position past the end means the two halves
    /// of the record disagree — resuming on a frame that is not in the list would put the
    /// painter somewhere the user never asked for.
    func testAPositionPastTheEndDoesNotResume() {
        XCTAssertNil(resume([0, 50, 99], 3))
        XCTAssertNil(resume([0, 50, 99], 400))
    }

    func testANegativePositionDoesNotResume() {
        XCTAssertNil(resume([0, 50, 99], -1))
    }

    /// config.json outlives the frames it was written for — it can be hand edited, and a
    /// sequence can be re-extracted shorter.  Indexing `frames` with what it says would trap.
    func testAFrameTheSequenceDoesNotHaveDoesNotResume() {
        XCTAssertNil(resume([0, 25, 900], 2, frames: 100))
        XCTAssertNil(resume([0, 25, 100], 2, frames: 100), "one past the end is still past it")
        XCTAssertNil(resume([-1], 0))
    }

    func testAnEmptySequenceDoesNotResume() {
        XCTAssertNil(resume([0], 0, frames: 0))
    }
}
