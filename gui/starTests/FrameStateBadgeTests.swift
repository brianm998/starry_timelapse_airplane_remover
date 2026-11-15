import XCTest
import AVFoundation
import SwiftUI
import Observation
import StarCore
import StarCppBridge
// The app target is named `Star`, not `star` — the lowercase name belongs to the .xcodeproj
// and to this test target.  TEST_HOST points at Star.app, so this is what links.
@testable import Star


/// Q2 (the owner's answer): the badges on the gui's grid and filmstrip cells and in its grid panel read the catalogue, as the desktop's do. They
/// were `shortString`, English words in every language ("class 1", "write values", "combine star align").
final class FrameStateBadgeTests: XCTestCase {
    override func tearDown() {
        StarLocalization.shared.languageOverride = nil
    }

    func testAFinishedFrameHasNoBadgeAndEveryOtherSaysItsCataloguePhrase() {
        StarLocalization.shared.languageOverride = "en"
        XCTAssertEqual(FrameProcessingState.complete.badgeText, "")
        for state in FrameProcessingState.allCases where state != .complete {
            XCTAssertEqual(state.badgeText, state.message, "\(state)")
            XCTAssertFalse(state.badgeText.isEmpty, "\(state)")
            XCTAssertFalse(state.badgeText.hasPrefix("frame_state."), "\(state) is missing from the catalogue")
        }
    }

    func testTheBadgeIsInTheUsersLanguageAndTheLogsKeyIsNot() {
        StarLocalization.shared.languageOverride = "en"
        let english = FrameProcessingState.detectingBlobs.badgeText
        let logKey = FrameProcessingState.detectingBlobs.shortString
        StarLocalization.shared.languageOverride = "de"
        XCTAssertNotEqual(FrameProcessingState.detectingBlobs.badgeText, english, "the badge is German in German")
        XCTAssertEqual(FrameProcessingState.detectingBlobs.shortString, logKey, "the updatable log's key does not change with the language")
    }

    func testTheThreeViewsAskForTheBadge() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for file in ["GridView", "FilmstripImageView", "GridRightPanel"] {
            let source = try String(contentsOf: root.appendingPathComponent("gui/star/\(file).swift"), encoding: .utf8)
            XCTAssertTrue(source.contains(".badgeText"), file)
            XCTAssertFalse(source.contains("frameState.shortString") || source.contains("state.shortString"), "\(file) still shows the English key")
        }
    }
}
