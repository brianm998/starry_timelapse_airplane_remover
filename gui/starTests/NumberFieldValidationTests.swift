import XCTest
import AVFoundation
import SwiftUI
import Observation
import StarCore
import StarCppBridge
// The app target is named `Star`, not `star` — the lowercase name belongs to the .xcodeproj
// and to this test target.  TEST_HOST points at Star.app, so this is what links.
@testable import Star


/// P5 (D4): a number typed into the settings sheet that the field does not take is marked and says what it takes, in the desktop client's words.
final class NumberFieldValidationTests: XCTestCase {
    override func setUp() { StarLocalization.shared.languageOverride = "en" }
    override func tearDown() { StarLocalization.shared.languageOverride = nil }

    func testAWholeNumberInRangeHasNothingWrongWithIt() {
        XCTAssertNil(EditableNumberView<Int>.validationMessage(for: "7", min: 1, max: 1000, allowDecimal: false))
        XCTAssertNil(EditableNumberView<Int>.validationMessage(for: "1000", min: 1, max: 1000, allowDecimal: false), "the bound itself")
    }

    func testOutOfRangeOrNotANumberSaysWhatIsTaken() {
        XCTAssertEqual(EditableNumberView<Int>.validationMessage(for: "5000", min: 1, max: 1000, allowDecimal: false), "Enter a whole number from 1 to 1000")
        XCTAssertEqual(EditableNumberView<Int>.validationMessage(for: "0", min: 1, max: 1000, allowDecimal: false), "Enter a whole number from 1 to 1000")
        XCTAssertEqual(EditableNumberView<Int>.validationMessage(for: "", min: 1, max: 1000, allowDecimal: false), "Enter a whole number from 1 to 1000")
    }

    func testADecimalReadsItsBoundsWithoutAPointZero() {
        XCTAssertNil(EditableNumberView<Double>.validationMessage(for: "0.5", min: 0.001, max: 10, allowDecimal: true))
        XCTAssertEqual(EditableNumberView<Double>.validationMessage(for: "11", min: 0.001, max: 10, allowDecimal: true), "Enter a number from 0.001 to 10")
        XCTAssertEqual(EditableNumberView<Double>.validationMessage(for: "9", min: 1, max: 8, allowDecimal: true), "Enter a number from 1 to 8")
    }

    func testItIsTheDesktopClientsSentenceInAnotherLanguageToo() {
        StarLocalization.shared.languageOverride = "de"
        let german = EditableNumberView<Int>.validationMessage(for: "0", min: 1, max: 9, allowDecimal: false)
        XCTAssertNotEqual(german, "Enter a whole number from 1 to 9")
        XCTAssertTrue(german?.contains("1") == true && german?.contains("9") == true)
    }
}
