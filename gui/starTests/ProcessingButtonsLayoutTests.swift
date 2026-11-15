import XCTest
import AVFoundation
import SwiftUI
import Observation
import StarCore
import StarCppBridge
// The app target is named `Star`, not `star` — the lowercase name belongs to the .xcodeproj
// and to this test target.  TEST_HOST points at Star.app, so this is what links.
@testable import Star


/// The bottom bar shows Process or Render Video, not both: Render Video only once
/// processing is complete, and in its place, so the pair does not take the room of two
/// buttons for one job.
@MainActor
final class ProcessingButtonsLayoutTests: XCTestCase {

    private func layout(
      processing: Bool = false,
      rendering: Bool = false,
      complete: Int = 0,
      frames: Int = 10,
      pendingHorizon: Bool = false
    ) -> ProcessingButtonsLayout {
        ProcessingButtonsLayout.current(
          isProcessingFrames: processing,
          isRenderingVideo: rendering,
          completeCount: complete,
          frameCount: frames,
          pendingHorizonRefinement: pendingHorizon
        )
    }

    func testAFreshSequenceShowsProcessAndNotRender() {
        XCTAssertEqual(layout(complete: 0),
                       ProcessingButtonsLayout(showsProcess: true, showsRender: false, renderEnabled: false))
    }

    func testASequencePartWayThroughShowsProcessAndNotRender() {
        XCTAssertEqual(layout(complete: 9),
                       ProcessingButtonsLayout(showsProcess: true, showsRender: false, renderEnabled: false))
    }

    /// The Show Progress button is the Process button in its other role, and keeps its place.
    func testARunInProgressShowsItsStatusAndNotRender() {
        XCTAssertEqual(layout(processing: true, complete: 4),
                       ProcessingButtonsLayout(showsProcess: true, showsRender: false, renderEnabled: false))
    }

    /// The last frame can be complete a moment before the run is over.
    func testEveryFrameCompleteWhileTheRunIsStillGoingIsNotComplete() {
        XCTAssertEqual(layout(processing: true, complete: 10),
                       ProcessingButtonsLayout(showsProcess: true, showsRender: false, renderEnabled: false))
    }

    func testACompleteSequenceShowsRenderVideoInPlaceOfProcess() {
        XCTAssertEqual(layout(complete: 10),
                       ProcessingButtonsLayout(showsProcess: false, showsRender: true, renderEnabled: true))
    }

    func testAVideoBeingWrittenLeavesRenderOnScreenButOff() {
        XCTAssertEqual(layout(rendering: true, complete: 10),
                       ProcessingButtonsLayout(showsProcess: false, showsRender: true, renderEnabled: false))
    }

    /// A horizon reference still to be applied is work the sequence is owed, so it is not
    /// done, whatever its frame states say.
    func testAPendingHorizonRefinementIsNotComplete() {
        XCTAssertEqual(layout(complete: 10, pendingHorizon: true),
                       ProcessingButtonsLayout(showsProcess: true, showsRender: false, renderEnabled: false))
    }

    /// 0 == 0 is not a finished sequence; there is nothing to render a video from.
    func testNoFramesIsNotComplete() {
        XCTAssertEqual(layout(complete: 0, frames: 0),
                       ProcessingButtonsLayout(showsProcess: true, showsRender: false, renderEnabled: false))
    }
}
