import XCTest
import AVFoundation
import SwiftUI
import Observation
import StarCore
import StarCppBridge
// The app target is named `Star`, not `star` — the lowercase name belongs to the .xcodeproj
// and to this test target.  TEST_HOST points at Star.app, so this is what links.
@testable import Star


/// S8: the start screen's controls are the ones `gherkin/ui/vectors/startScreen.json` lists, in that order, each with its hover text; the
/// desktop's `StartScreenTest` reads its own start screen against the same file.
final class StartScreenTests: XCTestCase {
    private static var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    func testTheControlsAreTheVectorsInOrderWithTheirHoverTexts() throws {
        let doc = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: Self.root.appendingPathComponent("gherkin/ui/vectors/startScreen.json"))) as? [String: Any])
        let controls = try XCTUnwrap(doc["controls"] as? [[String: String]])
        let source = try String(contentsOf: Self.root.appendingPathComponent("gui/star/InitialView.swift"), encoding: .utf8)
        var last = source.startIndex
        for control in controls {
            let label = try XCTUnwrap(control["label"])
            let tip = try XCTUnwrap(control["tip"])
            let found = try XCTUnwrap(source.range(of: "localized(\"\(label)\")", range: last..<source.endIndex), "\(label) is not on the start screen, or is out of order")
            last = found.upperBound
            XCTAssertTrue(source.contains(".help(localized(\"\(tip)\"))"), "\(control["id"] ?? "") has no hover text")
        }
    }

    /// D12: a recent can be removed from the list, and the button says so when hovered, as the desktop's ✕ does.
    func testARecentCanBeRemovedAndSaysSo() throws {
        let doc = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: Self.root.appendingPathComponent("gherkin/ui/vectors/startScreen.json"))) as? [String: Any])
        let key = try XCTUnwrap(doc["removeRecent"] as? String)
        let source = try String(contentsOf: Self.root.appendingPathComponent("gui/star/InitialView.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains(".help(localized(\"\(key)\"))"), "the remove button has no hover text")
        XCTAssertTrue(source.contains("removeFromRecent(filename:"), "the button does not take the entry off the list")
        defer { StarLocalization.shared.languageOverride = nil }
        StarLocalization.shared.languageOverride = "en"
        let english = localized(key)
        XCTAssertNotEqual(english, key, "\(key) is missing from the catalogue")
        StarLocalization.shared.languageOverride = "de"
        XCTAssertNotEqual(localized(key), english, "\(key) is English in German")
    }

    /// A1: the recents are a list with a row per entry, each with its own ✕ and ids, as the desktop's; no picker with one ✕ for the shown entry.
    func testRecentsAreAListWithARemovePerRow() throws {
        let source = try String(contentsOf: Self.root.appendingPathComponent("gui/star/InitialView.swift"), encoding: .utf8)
        XCTAssertFalse(source.contains("Picker("), "the recents are still a picker")
        XCTAssertFalse(source.contains("previously_opened_sheet_showing_item"))
        let list = try XCTUnwrap(source.range(of: "struct RecentsListView"), "no recents list")
        let body = String(source[list.lowerBound...])
        XCTAssertTrue(body.contains("ForEach(recent, id: \\.self)"), "no row per entry")
        XCTAssertTrue(source.contains("RecentsListView(recent: recent"), "the start screen does not show the list")
        XCTAssertTrue(source.contains("viewModel.userPreferences.sortedSequenceList"), "the list is not the recents")
        let row = try XCTUnwrap(body.range(of: "ForEach(recent"))
        let inRow = String(body[row.lowerBound...])
        XCTAssertTrue(inRow.contains("accessibilityIdentifier(\"startup.recent.open\")"), "a row has no open id")
        XCTAssertTrue(inRow.contains("accessibilityIdentifier(\"startup.recent.remove\")"), "a row has no remove id")
        XCTAssertTrue(inRow.contains(".help(localized(\"ui.remove_from_recent\"))"), "a row's ✕ has no hover text")
        XCTAssertTrue(inRow.contains("onRemove(path)"), "a row's ✕ does not remove its own entry")
        XCTAssertTrue(source.contains("removeFromRecent(filename: $0)"))
        // a config.json is titled by its folder, the rest by their own name
        XCTAssertEqual(RecentsListView.titleAndLocation(of: "/a/b/seq/config.json").title, "seq")
        XCTAssertEqual(RecentsListView.titleAndLocation(of: "/a/b/seq/config.json").location, "/a/b")
        XCTAssertEqual(RecentsListView.titleAndLocation(of: "/a/b/clip.mov").title, "clip.mov")
        XCTAssertEqual(RecentsListView.titleAndLocation(of: "/a/b/clip.mov").location, "/a/b")
    }

    /// A2: a recent opens by its kind, from the cases the desktop's `RecentOpenKindTest` runs too, and `loadRecent` routes by them.
    func testRecentOpenKindsAreTheVectors() throws {
        let doc = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: Self.root.appendingPathComponent("gherkin/ui/vectors/recentOpenKinds.json"))) as? [String: Any])
        let cases = try XCTUnwrap(doc["cases"] as? [[String: String]])
        XCTAssertGreaterThanOrEqual(cases.count, 15, "the vector lost cases")
        for c in cases {
            let path = try XCTUnwrap(c["path"])
            XCTAssertEqual(InitialView.openKind(for: path).rawValue, c["kind"], path)
        }
        let source = try String(contentsOf: Self.root.appendingPathComponent("gui/star/InitialView.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("switch Self.openKind(for: path)"), "loadRecent does not route by kind")
        XCTAssertFalse(source.contains("func loadRecent()"), "a recent is still always opened as a config")
    }

    private func zoneSource() throws -> String {
        try String(contentsOf: Self.root.appendingPathComponent("gui/star/FinderStyleDropZone.swift"), encoding: .utf8)
    }

    /// The drop zone is the reference for the desktop's: this key, the drop art and a dashed border that turns accent while a drag is over it.
    func testTheDropZoneSaysItsKey() throws {
        let source = try zoneSource()
        XCTAssertTrue(source.contains("localized(\"ui.drop_a_video_an_image_sequence_or_an\")"))
        XCTAssertTrue(source.contains("ArtImage(FinderStyleDropZone.art(isTargeted: isTargeted))"))
        XCTAssertTrue(source.contains("dash: [5]"))
        XCTAssertTrue(source.contains("isTargeted ? Color.accentColor"))
    }

    /// Clicking the zone opens the image sequence chooser (as the desktop's does), and hovering says so.
    func testTheDropZoneIsClickable() throws {
        let source = try zoneSource()
        XCTAssertTrue(source.contains(".onTapGesture(perform: onTap)"), "the zone has no click handler")
        XCTAssertTrue(source.contains(".help(localized(\"ui.load_an_image_sequence_yet_to_be_processed\"))"), "the zone has no hover text")
        XCTAssertTrue(source.contains("accessibilityIdentifier(\"startup.dropzone\")"))
        let view = try String(contentsOf: Self.root.appendingPathComponent("gui/star/InitialView.swift"), encoding: .utf8)
        XCTAssertTrue(view.contains("onTap: loadImageSequence"), "the zone's click does not load an image sequence")
    }
}
