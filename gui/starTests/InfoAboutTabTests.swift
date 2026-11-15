import XCTest
import AVFoundation
import SwiftUI
import Observation
import StarCore
import StarCppBridge
// The app target is named `Star`, not `star` — the lowercase name belongs to the .xcodeproj
// and to this test target.  TEST_HOST points at Star.app, so this is what links.
@testable import Star



/// The About tab is drawn from six catalogue keys, in order, with the source link after the license.
final class InfoAboutTabTests: XCTestCase {
    override func setUp() { StarLocalization.shared.languageOverride = "en" }
    override func tearDown() { StarLocalization.shared.languageOverride = nil }

    func testAboutTabFromCatalogue() {
        XCTAssertEqual(InfoType.aboutKeys,
                       ["ui.info_about_name", "ui.info_about_purpose", "ui.info_about_license",
                        "ui.info_about_what_it_does", "ui.info_about_video_formats", "ui.info_about_image_formats"])
        XCTAssertEqual(STAR_SOURCE_URL, "https://github.com/brianm998/starry_timelapse_airplane_remover")
        XCTAssertFalse(InfoType.about.infoText.contains("LINK to source code here"))
        XCTAssertTrue(InfoType.about.infoText.hasPrefix("Star is the Starry Timelapse Airplane Remover."))
        let english = InfoType.aboutKeys.map { localized($0) }
        StarLocalization.shared.languageOverride = "de"
        for (i, key) in InfoType.aboutKeys.enumerated() {
            XCTAssertNotEqual(localized(key), english[i], key)
        }
    }
}
