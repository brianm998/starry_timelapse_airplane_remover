import XCTest
import AVFoundation
import SwiftUI
import Observation
import StarCore
import StarCppBridge
// The app target is named `Star`, not `star` — the lowercase name belongs to the .xcodeproj
// and to this test target.  TEST_HOST points at Star.app, so this is what links.
@testable import Star


/// The gui's bottom status bar no longer carries the old sequence-alignment phase line the
/// desktop never had; the "N frames processing" line and Stop stay.
final class BottomStatusTests: XCTestCase {
    private static var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: Self.root.appendingPathComponent(path), encoding: .utf8)
    }

    func testTheAlignmentPhaseLineIsGone() throws {
        let bar = try source("gui/star/BottomRightView.swift")
        XCTAssertFalse(bar.contains("sequenceProcessingState"), "the bottom bar still reads sequenceProcessingState")
        for key in ["ui.detecting_horizons", "ui.star_keypoints", "ui.earth_keypoints", "ui.first_alignment",
                    "ui.second_alignment", "ui.alignment_done", "ui.alignment_error", "ui.n_frames_left"] {
            XCTAssertFalse(bar.contains("\"\(key)\""), "\(key) is still drawn in the bottom bar")
        }
        XCTAssertTrue(bar.contains("localized(\"ui.n_frames_processing\""), "the N frames processing line is gone")
        XCTAssertTrue(bar.contains("viewModel.stopProcessing()"), "the Stop button is gone")

        let model = try source("gui/star/ImageSequenceViewModel.swift")
        XCTAssertFalse(model.contains("sequenceProcessingState"), "nothing reads it, so the view model should not keep it")
    }
}
