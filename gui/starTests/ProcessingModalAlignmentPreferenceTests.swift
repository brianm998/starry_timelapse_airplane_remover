import XCTest
import AVFoundation
import SwiftUI
import Observation
import StarCore
import StarCppBridge
// The app target is named `Star`, not `star` — the lowercase name belongs to the .xcodeproj
// and to this test target.  TEST_HOST points at Star.app, so this is what links.
@testable import Star


/// Whether the processing modal draws its alignment charts is a preference rather than view
/// state, because the modal is torn down and rebuilt each time it is dismissed and brought
/// back — state there would forget the answer every time.
final class ProcessingModalAlignmentPreferenceTests: XCTestCase {

    func testAPreferencesFileWithoutTheKeyLeavesItUnset() throws {
        let json = #"{"recentlyOpenedSequencelist":{}}"#
        let prefs = try JSONDecoder().decode(UserPreferences.self, from: Data(json.utf8))
        XCTAssertNil(prefs.showAlignmentInProcessingWindow)
    }

    /// Someone who never chose gets the charts off: they are the tall half of the panel.
    func testTheChartsAreOffWhenNeverChosen() throws {
        let json = #"{"recentlyOpenedSequencelist":{}}"#
        let prefs = try JSONDecoder().decode(UserPreferences.self, from: Data(json.utf8))
        XCTAssertFalse(prefs.showsAlignmentInProcessingWindow)
    }

    /// Decoded rather than assigned: every setter on `UserPreferences` writes the real
    /// preferences file in the home directory, so a test that assigns one clobbers the
    /// user's own settings.
    func testTheChoiceRoundTrips() throws {
        for chosen in [true, false] {
            let json = """
              {"recentlyOpenedSequencelist":{},"showAlignmentInProcessingWindow":\(chosen)}
              """
            let prefs = try JSONDecoder().decode(UserPreferences.self, from: Data(json.utf8))
            XCTAssertEqual(prefs.showAlignmentInProcessingWindow, chosen)
            XCTAssertEqual(prefs.showsAlignmentInProcessingWindow, chosen)

            let encoded = try JSONEncoder().encode(prefs)
            XCTAssertTrue(String(decoding: encoded, as: UTF8.self)
                            .contains("showAlignmentInProcessingWindow"))

            let back = try JSONDecoder().decode(UserPreferences.self, from: encoded)
            XCTAssertEqual(back.showAlignmentInProcessingWindow, chosen)
        }
    }
}
