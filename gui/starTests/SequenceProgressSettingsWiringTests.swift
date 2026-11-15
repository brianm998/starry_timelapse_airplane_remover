import XCTest
import AVFoundation
import SwiftUI
import Observation
import StarCore
import StarCppBridge
// The app target is named `Star`, not `star` — the lowercase name belongs to the .xcodeproj
// and to this test target.  TEST_HOST points at Star.app, so this is what links.
@testable import Star


final class SequenceProgressSettingsWiringTests: XCTestCase {
    private func source(_ name: String) throws -> String {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: dir.appendingPathComponent("star/\(name)"), encoding: .utf8)
    }

    /// The sheet is attached inside `BottomRightView`'s edit-mode branch and a re-opened
    /// sequence is in `.scrub`, so raising the flag without entering edit mode shows nothing.
    func testSettingsClosesThePanelEntersEditModeAndRaisesTheSettingsSheet() throws {
        let model = try source("ImageSequenceViewModel.swift")
        let start = try XCTUnwrap(model.range(of: "func openSettingsForOpenedSequence()"))
        let end = try XCTUnwrap(model.range(of: "}", range: start.upperBound..<model.endIndex))
        let body = String(model[start.upperBound..<end.lowerBound])

        let close = try XCTUnwrap(body.range(of: "sequenceProgressModalShowing = false"))
        let edit = try XCTUnwrap(body.range(of: "enterEditMode()"))
        let sheet = try XCTUnwrap(body.range(of: "shouldShowProcessingSettings = true"))
        XCTAssertLessThan(close.lowerBound, edit.lowerBound)
        XCTAssertLessThan(edit.lowerBound, sheet.lowerBound,
                          "the flag set before edit mode is set from .scrub, where no sheet is attached")

        XCTAssertTrue(try source("SequenceProgressView.swift")
                        .contains("openSettings: { viewModel.openSettingsForOpenedSequence() }"))
        XCTAssertTrue(try source("BottomRightView.swift")
                        .contains("$viewModel.shouldShowProcessingSettings"))
    }
}
