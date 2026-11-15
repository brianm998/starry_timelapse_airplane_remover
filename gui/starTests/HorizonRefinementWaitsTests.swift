import XCTest
import AVFoundation
import SwiftUI
import Observation
import StarCore
import StarCppBridge
// The app target is named `Star`, not `star` — the lowercase name belongs to the .xcodeproj
// and to this test target.  TEST_HOST points at Star.app, so this is what links.
@testable import Star


/// L9 (the owner's answer): a horizon refinement waits for the run that is going, in the gui as in the desktop.
final class HorizonRefinementWaitsTests: XCTestCase {
    func testItNeedsSomethingPendingAndNoRunGoing() {
        XCTAssertTrue(ImageSequenceViewModel.canRefineHorizonsNow(isProcessingFrames: false, hasPending: true))
        XCTAssertFalse(ImageSequenceViewModel.canRefineHorizonsNow(isProcessingFrames: true, hasPending: true), "a run is going")
        XCTAssertFalse(ImageSequenceViewModel.canRefineHorizonsNow(isProcessingFrames: false, hasPending: false), "nothing to refine")
    }

    func testTheButtonAndTheNowAnswerBothWait() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let model = try String(contentsOf: root.appendingPathComponent("gui/star/ImageSequenceViewModel.swift"), encoding: .utf8)
        let body = model.components(separatedBy: "func reprocessHorizonsForUpdatedReferences() {").last ?? ""
        XCTAssertTrue(body.prefix(400).contains("guard !isProcessingFrames"), "\"Now\" during a run claims nothing")
        let panel = try String(contentsOf: root.appendingPathComponent("gui/star/RightPanel.swift"), encoding: .utf8)
        XCTAssertTrue(panel.contains(".disabled(!viewModel.canRefineHorizonsNow)"))
    }
}
