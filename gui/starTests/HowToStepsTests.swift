import XCTest
import AVFoundation
import SwiftUI
import Observation
import StarCore
import StarCppBridge
// The app target is named `Star`, not `star` — the lowercase name belongs to the .xcodeproj
// and to this test target.  TEST_HOST points at Star.app, so this is what links.
@testable import Star



/// The How To tab is five steps, each with its robot and as many labels as its paragraph has placeholders.
final class HowToStepsTests: XCTestCase {
    override func setUp() { StarLocalization.shared.languageOverride = "en" }
    override func tearDown() { StarLocalization.shared.languageOverride = nil }

    func testHowToSteps() {
        let steps = InfoType.howToSteps
        XCTAssertEqual(steps.map(\.art.rawValue),
                       ["art_howto_import", "art_howto_questions", "art_howto_process", "art_review", "art_rendering"])
        XCTAssertEqual(steps.map(\.titleKey),
                       ["import", "questions", "process", "review", "render"].map { "ui.info_how_to_\($0)_title" })
        XCTAssertEqual(steps.map(\.bodyKey),
                       ["import", "questions", "process", "review", "render"].map { "ui.info_how_to_\($0)_body" })
        XCTAssertEqual(steps.map(\.placeholderKeys),
                       [["ui.load_video", "ui.load_image_sequence"], ["ui.processing_settings"],
                        ["ui.start_processing"], [], ["ui.render_video", "ui.load_config"]])
        for code in ["en", "de"] {
            StarLocalization.shared.languageOverride = code
            for step in steps {
                let raw = localized(step.bodyKey)
                let count = (0..<5).filter { raw.contains("{\($0)}") }.count
                XCTAssertEqual(count, step.placeholderKeys.count, "\(code) \(step.bodyKey)")
                XCTAssertFalse(step.body.contains("{"), "\(code) \(step.bodyKey)")
            }
        }
        StarLocalization.shared.languageOverride = "en"
        XCTAssertEqual(steps[0].heading, "Open your footage")
        XCTAssertTrue(steps[0].body.hasPrefix("Click Load Video to open"))
    }
}
