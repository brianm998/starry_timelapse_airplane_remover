import XCTest
import AVFoundation
import SwiftUI
import Observation
import StarCore
import StarCppBridge
// The app target is named `Star`, not `star` — the lowercase name belongs to the .xcodeproj
// and to this test target.  TEST_HOST points at Star.app, so this is what links.
@testable import Star


/// The settings sheet's tab titles: black on the selected pill, white on the grey track otherwise, yellow when disabled.
final class SettingsTabTitleColorTests: XCTestCase {
    func testSelectedTabIsBlackAndUnselectedIsWhite() {
        XCTAssertEqual(settingsTabTitleColor(isSelected: true, isEnabled: true), .black)
        XCTAssertEqual(settingsTabTitleColor(isSelected: false, isEnabled: true), .white)
    }

    func testDisabledTabsStayYellow() {
        XCTAssertEqual(settingsTabTitleColor(isSelected: true, isEnabled: false), .yellow)
        XCTAssertEqual(settingsTabTitleColor(isSelected: false, isEnabled: false), .yellow)
    }
}
