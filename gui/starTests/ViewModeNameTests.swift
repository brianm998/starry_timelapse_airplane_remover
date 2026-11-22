import XCTest
import AVFoundation
import SwiftUI
import Observation
import StarCore
import StarCppBridge
// The app target is named `Star`, not `star` — the lowercase name belongs to the .xcodeproj
// and to this test target.  TEST_HOST points at Star.app, so this is what links.
@testable import Star


/// Q1: the mode names the pickers and the "image not found" line use come from the catalogue (the desktop reads the same keys);
/// `longName` was a switch of English literals.
final class ViewModeNameTests: XCTestCase {
    override func tearDown() {
        StarLocalization.shared.languageOverride = nil
    }

    func testTheEnglishNamesAreTheOnesTheSwitchHad() {
        StarLocalization.shared.languageOverride = "en"
        XCTAssertEqual(FrameViewMode.final.longName, "final processed frame")
        XCTAssertEqual(FrameViewMode.original.longName, "original frame")
        XCTAssertEqual(FrameViewMode.starAligned.longName, "star aligned frame")
        XCTAssertEqual(FrameViewMode.failedStarAligned.longName, "failed star align frame")
        XCTAssertEqual(FrameViewMode.consensusHorizon.longName, "horizon consensus")
    }

    func testEveryModeHasAGermanName() {
        StarLocalization.shared.languageOverride = "en"
        let english = FrameViewMode.allCases.map(\.longName)
        StarLocalization.shared.languageOverride = "de"
        for (mode, inEnglish) in zip(FrameViewMode.allCases, english) {
            let german = mode.longName
            XCTAssertFalse(german.hasPrefix("view_mode."), "\(mode): the key is missing from the catalogue")
            XCTAssertNotEqual(german, inEnglish, "\(mode) is still English in German")
        }
    }

    /// Q8: the pickers at the bottom left read the catalogue (they showed `rawValue` and `shortName`, English in every language), with the
    /// same keys as the desktop's `ModePickersTest`.
    func testTheBottomLeftPickersReadTheCatalogue() throws {
        StarLocalization.shared.languageOverride = "en"
        XCTAssertEqual(BottomLeftView.viewLabel(.original), "Original")
        XCTAssertEqual(BottomLeftView.viewLabel(.final), "Processed")
        XCTAssertEqual(InteractionMode.edit.localizedName, "Edit")
        StarLocalization.shared.languageOverride = "de"
        XCTAssertEqual(BottomLeftView.viewLabel(.final), "Bearbeitet")
        XCTAssertEqual(InteractionMode.edit.localizedName, "Bearbeiten")
        XCTAssertNotEqual(localized("ui.interaction_mode_help"), "ui.interaction_mode_help")
        let source = try String(contentsOfFile: #filePath.replacingOccurrences(of: "starTests/ViewModeNameTests.swift", with: "star/BottomLeftView.swift"), encoding: .utf8)
        XCTAssertFalse(source.contains("value.rawValue"), "the mode names were English")
        XCTAssertFalse(source.contains("value.shortName"), "the view names were English")
        XCTAssertTrue(source.contains("localized(\"ui.interaction_mode_help\")"))
    }

    /// P6: the settings sheet's clean-method rows have headings and choices in the user's language (the help and description under them
    /// are still English, `HighLevelCleanMethod.helpText` and the others).
    func testTheCleanMethodRowsAreTitledInTheUsersLanguage() {
        StarLocalization.shared.languageOverride = "en"
        XCTAssertEqual(HighLevelCleanMethod.automatic.titleText, "Automatic")
        XCTAssertEqual(HighLevelCleanMethod.selective.titleText, "Selective")
        XCTAssertEqual(HighLevelCleanMethod.topTitle, "Clean Method:")
        XCTAssertEqual(AutoPreservationMode.topTitle, "Selective Auto Clean:")
        XCTAssertEqual(AutoPreservationMode.yes.titleText, "Yes")
        let english = [HighLevelCleanMethod.topTitle, AutoPreservationMode.topTitle, HighLevelCleanMethod.automatic.titleText, AutoPreservationMode.no.titleText]
        StarLocalization.shared.languageOverride = "de"
        let german = [HighLevelCleanMethod.topTitle, AutoPreservationMode.topTitle, HighLevelCleanMethod.automatic.titleText, AutoPreservationMode.no.titleText]
        for (g, e) in zip(german, english) { XCTAssertNotEqual(g, e) }
    }

    func testTheNotFoundLineNamesTheMode() throws {
        let source = try String(contentsOfFile: #filePath.replacingOccurrences(of: "starTests/ViewModeNameTests.swift", with: "star/FrameViewModel.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("failure: .preview(type.longName)"))
        let panel = try String(contentsOfFile: #filePath.replacingOccurrences(of: "starTests/ViewModeNameTests.swift", with: "star/FrameImageLoader.swift"), encoding: .utf8)
        XCTAssertTrue(panel.contains("localized(\"ui.image_not_found_for_frame\", name)"))
    }
}
