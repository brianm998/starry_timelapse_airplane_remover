import XCTest
import AVFoundation
import SwiftUI
import Observation
import StarCore
import StarCppBridge
// The app target is named `Star`, not `star` — the lowercase name belongs to the .xcodeproj
// and to this test target.  TEST_HOST points at Star.app, so this is what links.
@testable import Star


/// The two multi-frame sheets are titled as `gherkin/ui/vectors/multiSheets.json` says, and the area sheet has the Trash switch the desktop's has; the
/// desktop's `MultiSheetLayoutTest` reads its own sheets against the same file.
final class MultiSheetLayoutTests: XCTestCase {
    private static var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func vector() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: Self.root.appendingPathComponent("gherkin/ui/vectors/multiSheets.json"))) as? [String: Any])
    }

    private func source(_ name: String) throws -> String {
        try String(contentsOf: Self.root.appendingPathComponent("gui/star/\(name)"), encoding: .utf8)
    }

    func testTheTitlesAreInTheVector() throws {
        let doc = try vector()
        XCTAssertTrue(try source("MultiChoiceSheetView.swift").contains("Text(localized(\"\(try XCTUnwrap(doc["overlapTitle"] as? String))\"))"))
        XCTAssertTrue(try source("MultiSelectSheetView.swift").contains("Text(localized(\"\(try XCTUnwrap(doc["areaTitle"] as? String))\"))"))
    }

    /// D12: the area sheet has a Trash switch that starts at the right panel's Show Trash, and both applies use its value, not Show Trash.
    func testTheAreaSheetHasATrashSwitch() throws {
        let label = try XCTUnwrap(try vector()["trashLabel"] as? String)
        let area = try source("MultiSelectSheetView.swift")
        XCTAssertTrue(area.contains("Toggle(localized(\"\(label)\"), isOn: $includingTrash)"), "the sheet has no Trash switch")
        XCTAssertTrue(area.contains("includingTrash = viewModel.shouldShowTrash"), "the switch does not start at Show Trash")
        XCTAssertEqual(area.components(separatedBy: "includingTrash: includingTrash").count - 1, 2, "both applies should use the switch")
        XCTAssertFalse(area.contains("includingTrash: viewModel.shouldShowTrash"), "an apply still ignores the switch")
    }
}
