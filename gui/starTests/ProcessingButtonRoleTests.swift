import XCTest
import AVFoundation
import SwiftUI
import Observation
import StarCore
import StarCppBridge
// The app target is named `Star`, not `star` — the lowercase name belongs to the .xcodeproj
// and to this test target.  TEST_HOST points at Star.app, so this is what links.
@testable import Star



/// The left panel's top button is two buttons sharing one place on screen, and the rule for
/// which one it is has a trap in it: the frame counts that decide whether there is anything
/// left to process must not be allowed to disable the Status button.  A run that has just
/// claimed the last unprocessed frame would otherwise take away the only way back to its
/// own processing modal, which the modal's Dismiss button puts down.
@MainActor
final class ProcessingButtonRoleTests: XCTestCase {

    private func role(
      processing: Bool = false,
      rendering: Bool = false,
      unprocessed: Int = 0,
      horizonDetected: Int = 0,
      frames: Int = 10,
      pendingHorizon: Bool = false
    ) -> ProcessingButtonRole {
        ProcessingButtonRole.current(
          isProcessingFrames: processing,
          isRenderingVideo: rendering,
          unprocessedCount: unprocessed,
          horizonDetectedCount: horizonDetected,
          frameCount: frames,
          pendingHorizonRefinement: pendingHorizon
        )
    }

    func testAFreshSequenceOffersToProcess() {
        XCTAssertEqual(role(unprocessed: 10), .process(enabled: true))
    }

    func testARunInProgressOffersItsStatus() {
        XCTAssertEqual(role(processing: true, unprocessed: 4), .status)
    }

    /// The regression this exists for.
    func testTheStatusButtonSurvivesTheLastFrameBeingClaimed() {
        XCTAssertEqual(role(processing: true, unprocessed: 0, horizonDetected: 0), .status)
    }

    /// `.status` carries no enabled flag at all, which is the point: there is no state in
    /// which the way back to a live run's modal is withheld.
    func testTheStatusButtonIsNeverDisabled() {
        for rendering in [false, true] {
            for unprocessed in [0, 1, 10] {
                for horizon in [0, 5, 10] {
                    XCTAssertEqual(role(processing: true, rendering: rendering,
                                        unprocessed: unprocessed, horizonDetected: horizon),
                                   .status)
                }
            }
        }
    }

    func testAFinishedSequenceHasNothingLeftToProcess() {
        XCTAssertEqual(role(unprocessed: 0, horizonDetected: 0), .process(enabled: false))
    }

    /// Every frame stopped after horizon detection is the one state with no unprocessed
    /// frames that is still worth processing from.
    func testASequenceStoppedAtHorizonDetectionCanStillBeProcessed() {
        XCTAssertEqual(role(unprocessed: 0, horizonDetected: 10, frames: 10),
                       .process(enabled: true))
    }

    func testSomeFramesAtHorizonDetectionIsNotEnough() {
        XCTAssertEqual(role(unprocessed: 0, horizonDetected: 6, frames: 10),
                       .process(enabled: false))
    }

    func testRenderingAVideoHoldsOffAnotherRun() {
        XCTAssertEqual(role(rendering: true, unprocessed: 10), .process(enabled: false))
    }

    /// A sequence every frame of which is finished, and which is still owed the horizon
    /// reference the user painted and put off applying.  By the frame states there is
    /// nothing to do — the frames whose render was taken away for it are not `.unprocessed`
    /// — so without this the run that would apply it could not be started.
    func testAPendingHorizonRefinementIsWorthProcessingFor() {
        XCTAssertEqual(role(unprocessed: 0, horizonDetected: 0, pendingHorizon: true),
                       .process(enabled: true))
    }

    /// It is work, not an override: a video being written still holds off the run that
    /// would do it.
    func testAPendingHorizonRefinementStillWaitsForAVideo() {
        XCTAssertEqual(role(rendering: true, pendingHorizon: true), .process(enabled: false))
    }

    /// And it does not change what a live run's button says.
    func testAPendingHorizonRefinementDoesNotHideTheStatusButton() {
        XCTAssertEqual(role(processing: true, pendingHorizon: true), .status)
    }
}
