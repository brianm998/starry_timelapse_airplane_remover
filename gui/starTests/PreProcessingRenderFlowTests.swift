import XCTest
import AVFoundation
import SwiftUI
import Observation
import StarCore
import StarCppBridge
// The app target is named `Star`, not `star` — the lowercase name belongs to the .xcodeproj
// and to this test target.  TEST_HOST points at Star.app, so this is what links.
@testable import Star


/// The pre-processing "Render video after processing?" prompt: Yes leads to the render options, "Use These Settings" starts processing with
/// auto-render on and the whole choice (resolution included) goes on to the automatic render, Cancel goes back to the question.
/// `ImageSequenceViewModel` cannot be built in a test, so the flow it holds is tested on its own.
final class PreProcessingRenderFlowTests: XCTestCase {

    private let chosen = RenderChoice(frameRate: .custom(29.97),
                                      codec: .prores,
                                      encoder: .prores,
                                      pixelFormat: .yuv444p10le,
                                      muxer: .mov,
                                      resolution: .p1080)

    func testYesThenConfirmStartsWithAutoRenderAndCarriesTheChoice() {
        var flow = PreProcessingRenderFlow()
        flow.open()
        XCTAssertEqual(flow.step, .asking)

        flow.yes()
        XCTAssertEqual(flow.step, .choosingOptions, "Yes asks how to render; it starts nothing")
        XCTAssertNil(flow.choice)

        let start = flow.confirm(chosen)
        XCTAssertEqual(start, .init(autoRender: true, dontAskAgain: false))
        XCTAssertEqual(flow.step, .closed)
        XCTAssertEqual(flow.choice, chosen)
        XCTAssertEqual(flow.choice?.resolution, .p1080, "the resolution is not a preference: it has to travel with the choice")
    }

    func testTheConfirmedChoiceIsHandedToTheAutoRenderOnce() {
        var flow = PreProcessingRenderFlow()
        flow.open()
        flow.yes()
        _ = flow.confirm(chosen)

        XCTAssertEqual(flow.takeChoice(), chosen)
        XCTAssertNil(flow.takeChoice(), "the post-processing prompt's Yes must not reuse it")

        // a choice left from an earlier question is not the answer to a new one
        flow.open()
        flow.yes()
        _ = flow.confirm(chosen)
        flow.open()
        XCTAssertNil(flow.choice)
    }

    func testCancelInTheOptionsReturnsToThePromptWithoutStarting() {
        var flow = PreProcessingRenderFlow()
        flow.open()
        flow.yes()
        flow.cancelOptions()
        XCTAssertEqual(flow.step, .asking)
        XCTAssertNil(flow.choice)
        XCTAssertNil(flow.confirm(chosen), "the options are not showing, so there is nothing to confirm")
        XCTAssertEqual(flow.step, .asking)

        flow.yes()
        XCTAssertEqual(flow.step, .choosingOptions, "Yes again goes on to the options")
    }

    func testNoAndDontAskAgainStartAsBefore() {
        var flow = PreProcessingRenderFlow()
        flow.open()
        XCTAssertEqual(flow.no(), .init(autoRender: false, dontAskAgain: false))
        XCTAssertEqual(flow.step, .closed)

        flow.open()
        XCTAssertEqual(flow.dontAskAgain(), .init(autoRender: false, dontAskAgain: true))
        XCTAssertEqual(flow.step, .closed)

        // neither keeps a choice
        flow.open()
        flow.yes()
        _ = flow.confirm(chosen)
        _ = flow.no()
        XCTAssertNil(flow.takeChoice())
    }

    func testTheViewModelActsOnTheFlow() throws {
        let model = try source("ImageSequenceViewModel.swift")
        XCTAssertTrue(model.contains("preProcessingFlow.yes()"))
        XCTAssertTrue(model.contains("renderVideoAutoChoice = preProcessingFlow.takeChoice()"), "the choice reaches the automatic render")
        XCTAssertTrue(model.contains("confirmStartProcessing(autoRender: start.autoRender, dontAskAgain: start.dontAskAgain)"))
        let prompt = try source("PreProcessingRenderPromptView.swift")
        XCTAssertTrue(prompt.contains("viewModel.chooseRenderOptions()"), "Yes no longer starts processing itself")
        XCTAssertTrue(prompt.contains("prompt.pre.yes") && prompt.contains("prompt.pre.no"))
        XCTAssertTrue(prompt.contains("prompt.options.confirm"))
        let sheet = try source("RenderVideoSheetView.swift")
        XCTAssertTrue(sheet.contains("autoChoice: RenderChoice?"), "the automatic render's sheet starts from the choice")
    }

    private func source(_ relativePath: String) throws -> String {
        let guiDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: guiDir.appendingPathComponent("star/\(relativePath)"), encoding: .utf8)
    }
}
