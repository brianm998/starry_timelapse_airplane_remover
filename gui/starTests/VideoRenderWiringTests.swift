import XCTest
import AVFoundation
import SwiftUI
import Observation
import StarCore
import StarCppBridge
// The app target is named `Star`, not `star` — the lowercase name belongs to the .xcodeproj
// and to this test target.  TEST_HOST points at Star.app, so this is what links.
@testable import Star


/// P12 of `plans/GUI_CLIENT_PARITY_PLAN.md`: the gui's Render Video made its own ffmpeg command from a glob, could not be stopped, and never
/// said a render was going (so Process stayed on and Quit did not ask).  It now builds the command the way the cli and the desktop do
/// (`VideoExport`), runs it so that cancelling terminates ffmpeg, and holds `isRenderingVideo` for as long as it goes.
final class VideoRenderWiringTests: XCTestCase {
    private func source(_ name: String) throws -> String {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: dir.appendingPathComponent("star/\(name)"), encoding: .utf8)
    }

    /// The text of `renderVideo(` up to the end of its error type, where the render is built.
    private func renderBody() throws -> String {
        let text = try source("ImageSequenceViewModel.swift")
        let start = try XCTUnwrap(text.range(of: "func renderVideo(named"))
        let end = try XCTUnwrap(text.range(of: "enum RenderVideoError", range: start.upperBound..<text.endIndex))
        return String(text[start.lowerBound..<end.lowerBound])
    }

    func testTheCommandComesFromVideoExportAndCanBeCancelled() throws {
        let body = try renderBody()
        XCTAssertTrue(body.contains("VideoExport.finalFrames"), "the frames are the files the sequence expects, not a glob")
        XCTAssertTrue(body.contains("VideoExport.concatList"))
        XCTAssertTrue(body.contains("VideoExport.arguments"))
        XCTAssertTrue(body.contains("runCancellableFFmpegWithProgress"), "a cancel has to terminate ffmpeg")
        XCTAssertFalse(body.contains("pattern_type"), "ffmpeg's glob is what VideoExport replaced")
    }

    func testARenderIsPendingWorkWhileItGoes() throws {
        let body = try renderBody()
        XCTAssertTrue(body.contains("isRenderingVideo = true"))
        XCTAssertTrue(body.contains("videoRenderEnded(token)"), "however the render ends, the flag comes down")
        XCTAssertTrue(try source("ImageSequenceViewModel.swift").contains("isRenderingVideo = false"))
        // The button that opened the sheet used to put the flag down again as it was opened.
        XCTAssertFalse(try source("BottomRightView.swift").contains("isRenderingVideo = false"))
    }

    func testTheSheetHasACancelAndClosingTheSequenceStopsTheRender() throws {
        let sheet = try source("RenderVideoSheetView.swift")
        XCTAssertTrue(sheet.contains("render.cancel"))
        XCTAssertTrue(sheet.contains("viewModel.cancelVideoRender()"))
        XCTAssertTrue(sheet.contains("error is CancellationError"), "a render the user stopped is not an error to show")
        XCTAssertTrue(try source("ViewModel.swift").contains("closing.cancelVideoRender()"))
    }

    /// P14: picking Custom keeps the rate in force (it put 24 there), and the field applies as it is typed.
    func testCustomKeepsTheCurrentRateAndTheFieldAppliesAsItIsTyped() throws {
        let sheet = try source("RenderVideoSheetView.swift")
        XCTAssertTrue(sheet.contains("frameRate = .custom(frameRate.rawValue)"), "Custom starts at the rate in force")
        XCTAssertFalse(sheet.contains(".onSubmit"), "a rate typed and not submitted used to be dropped")
        XCTAssertTrue(sheet.contains("ui.enter_a_number_from_a_to_b"))
    }

    /// Q14: "Processing N more frames" counted down from a number nothing set.
    func testTheFramesLeftAreTheOnesNotYetComplete() throws {
        let model = try source("ImageSequenceViewModel.swift")
        XCTAssertTrue(model.contains("var framesLeftToProcess: Int { max(0, frames.count - count(for: .complete)) }"))
        XCTAssertFalse(model.contains("numberOfFramesProcessed"), "the counter nothing updated")
        let view = try source("BottomRightView.swift")
        XCTAssertTrue(view.contains("localized(\"ui.processing_n_more_frames\", viewModel.framesLeftToProcess)"))
    }

    func testTheNoFramesErrorIsInTheUsersLanguage() {
        defer { StarLocalization.shared.languageOverride = nil }
        StarLocalization.shared.languageOverride = "en"
        let english = ImageSequenceViewModel.RenderVideoError.noFrames.errorDescription
        StarLocalization.shared.languageOverride = "de"
        let german = ImageSequenceViewModel.RenderVideoError.noFrames.errorDescription
        XCTAssertNotEqual(english, "ui.render_video_no_frames", "the key is missing from the catalogue")
        XCTAssertNotNil(german)
        XCTAssertNotEqual(german, english)
    }
}
