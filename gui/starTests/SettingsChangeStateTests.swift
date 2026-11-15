import XCTest
import AVFoundation
import SwiftUI
import Observation
import StarCore
import StarCppBridge
// The app target is named `Star`, not `star` — the lowercase name belongs to the .xcodeproj
// and to this test target.  TEST_HOST points at Star.app, so this is what links.
@testable import Star


/// The settings view was built for a sequence nothing has been done to, where every switch
/// it offers affects only work still to come.  Over a sequence part way through, a switch
/// that changes how the output looks splits it in two — some frames merged with earth
/// alignment and some without — and that is what these two halves are for.
///
/// Both halves have to hold at once, and each is silent on its own: a change with nothing
/// finished behind it is the ordinary first run, and finished work with no change behind it
/// is an ordinary resume.
@MainActor
final class SettingsChangeStateTests: XCTestCase {

    private func contradicts(
      processing: Bool = false,
      complete: Int = 0,
      userModified: Int = 0,
      openedUntouched: Bool? = nil,
      changed: Set<ArtifactStage> = [.output]
    ) -> Bool {
        SettingsChangeState.contradictsFinishedWork(
          isProcessingFrames: processing,
          completeFrameCount: complete,
          userModifiedFrameCount: userModified,
          openedSequenceWasUntouched: openedUntouched,
          changedStages: changed
        )
    }

    // MARK: - silent on its own

    func testAFirstRunOverAnUntouchedSequenceSaysNothing() {
        XCTAssertFalse(contradicts(openedUntouched: true))
    }

    func testAChangeWithNothingFinishedBehindItSaysNothing() {
        XCTAssertFalse(contradicts(changed: [.horizon, .keypoints, .output]))
    }

    /// The concurrency and memory knobs land here: `ArtifactInputs` records none of them,
    /// so they change nothing that is on disk and must not warn about it.
    func testFinishedWorkWithNoOutputAffectingChangeSaysNothing() {
        XCTAssertFalse(contradicts(complete: 40, openedUntouched: false, changed: []))
        XCTAssertFalse(contradicts(processing: true, changed: []))
    }

    // MARK: - both halves together

    func testAChangeOverFinishedFramesWarns() {
        XCTAssertTrue(contradicts(complete: 40, openedUntouched: false))
    }

    /// A run counts before its first frame is written: the horizon masks and keypoint sets
    /// it has already built were built under the old settings, and those are what a change
    /// throws away.
    func testAChangeDuringARunWarnsBeforeAnyFrameIsFinished() {
        XCTAssertTrue(contradicts(processing: true, complete: 0, openedUntouched: true))
    }

    /// Classified outliers are work too, and the settings that produced them are recorded.
    func testAChangeOverClassifiedFramesWarns() {
        XCTAssertTrue(contradicts(userModified: 12))
    }

    /// The half-finished sequence the feature exists for: re-opened, nothing merged yet,
    /// but hours of keypoints and alignment on disk behind it.
    func testAChangeOverAReopenedSequenceWithNoFinishedFramesWarns() {
        XCTAssertTrue(contradicts(complete: 0, openedUntouched: false))
    }

    /// No survey means this sequence was set up in this session, so there is nothing on
    /// disk from before to contradict.
    func testASequenceWithNoSurveyAndNoFinishedFramesSaysNothing() {
        XCTAssertFalse(contradicts(openedUntouched: nil))
    }

    /// Whichever stage moved, the answer is the same — the question is whether anything
    /// output-affecting changed, not which thing.
    func testAnyChangedStageIsEnough() {
        for stage in ArtifactStage.allCases {
            XCTAssertTrue(contradicts(complete: 1, changed: [stage]), "\(stage)")
        }
    }
}
