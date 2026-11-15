import XCTest
import AVFoundation
import SwiftUI
import Observation
import StarCore
import StarCppBridge
// The app target is named `Star`, not `star` — the lowercase name belongs to the .xcodeproj
// and to this test target.  TEST_HOST points at Star.app, so this is what links.
@testable import Star


/// The alignment window says what the desktop's does (`gherkin/ui/vectors/alignmentWindow.json`; the desktop's
/// `AlignmentWindowTextsTest` reads its own view against the same file): the same empty-state texts in the same states, the same
/// chart labels and the same zoom/pan/click help line.
final class AlignmentWindowTextsTests: XCTestCase {
    private static var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func vector() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: Self.root.appendingPathComponent("gherkin/ui/vectors/alignmentWindow.json"))) as? [String: Any])
    }

    private func source() throws -> String {
        try String(contentsOf: Self.root.appendingPathComponent("gui/star/AlignmentWindowView.swift"), encoding: .utf8)
    }

    /// The gui always has its alignment data in the view model, so the states the vector has for data not yet fetched do not arise here.
    func testTheEmptyStatesAreTheVectors() throws {
        let states = try XCTUnwrap(try vector()["emptyStates"] as? [[String: Any]])
        XCTAssertGreaterThanOrEqual(states.count, 6, "the vector lost states")
        var checked = 0
        for state in states {
            let hasSequence = try XCTUnwrap(state["hasSequence"] as? Bool)
            let fetched = try XCTUnwrap(state["fetched"] as? Bool)
            if hasSequence && !fetched { continue }
            let got = AlignmentWindowView.emptyState(
              hasSequence: hasSequence,
              hasData: try XCTUnwrap(state["hasData"] as? Bool),
              processing: try XCTUnwrap(state["processing"] as? Bool))
            XCTAssertEqual(got, state["lines"] as? [String], "state \(state["id"] ?? "")")
            checked += 1
        }
        XCTAssertGreaterThanOrEqual(checked, 5)
        let view = try source()
        XCTAssertTrue(view.contains("Self.emptyState("), "the window does not pick its text from the shared states")
        defer { StarLocalization.shared.languageOverride = nil }
        StarLocalization.shared.languageOverride = "en"
        for state in states {
            for key in try XCTUnwrap(state["lines"] as? [String]) {
                XCTAssertNotEqual(localized(key), key, "\(key) is missing from the catalogue")
            }
        }
    }

    /// The waiting robot is drawn exactly when the window shows empty-state lines, and the trouble and waiting art is in its views.
    func testAlignmentEmptyStateArt() throws {
        let states = try XCTUnwrap(try vector()["emptyStates"] as? [[String: Any]])
        var checked = 0
        for state in states {
            let hasSequence = try XCTUnwrap(state["hasSequence"] as? Bool)
            let fetched = try XCTUnwrap(state["fetched"] as? Bool)
            if hasSequence && !fetched { continue }
            let lines = try XCTUnwrap(state["lines"] as? [String])
            let art = AlignmentWindowView.emptyStateArt(
              hasSequence: hasSequence,
              hasData: try XCTUnwrap(state["hasData"] as? Bool),
              processing: try XCTUnwrap(state["processing"] as? Bool))
            XCTAssertEqual(art, lines.isEmpty ? nil : .waiting, "state \(state["id"] ?? "")")
            checked += 1
        }
        XCTAssertGreaterThanOrEqual(checked, 5)
        func src(_ f: String) throws -> String {
            try String(contentsOf: Self.root.appendingPathComponent("gui/star/\(f)"), encoding: .utf8)
        }
        XCTAssertTrue(try src("AlignmentWindowView.swift").contains("WaitingArt()"))
        XCTAssertTrue(try src("BlobProcessingView.swift").contains("WaitingArt()"))
        XCTAssertTrue(try src("OutlierGroupTable.swift").contains("WaitingArt()"))
        XCTAssertTrue(try src("ContentView.swift").contains("ArtImage(.oops)"))
        XCTAssertTrue(try src("ContentView.swift").contains("ArtImage(.holdOn)"))
        XCTAssertEqual(try src("AppDelegate.swift").components(separatedBy: "alert.icon = NSImage(named: StarArt.holdOn.rawValue)").count - 1, 2)
        XCTAssertTrue(try src("NewReleaseSheetView.swift").contains("ArtImage(.newRelease)"))
    }

    func testTheChartLabelsAreTheVectors() throws {
        let doc = try vector()
        let labels = try XCTUnwrap(doc["chartLabels"] as? [String: String])
        let help = try XCTUnwrap(doc["help"] as? String)
        let view = try source()
        func label(_ id: String) throws -> String { try XCTUnwrap(labels[id], id) }

        for id in ["currentFrame", "hoverFrame", "keypointSeries", "keypointValue", "frame"] {
            let key = try label(id)
            XCTAssertTrue(view.contains("localized(\"\(key)\")"), "\(id) (\(key)) does not name a chart mark")
        }
        XCTAssertTrue(view.contains(".chartXAxisLabel(localized(\"\(try label("xAxis"))\"))"))
        XCTAssertTrue(view.contains(".chartYAxisLabel(localized(\"\(try label("keypointYAxis"))\"))"))
        XCTAssertTrue(view.contains("Text(localized(\"\(try label("starKeypointsTitle"))\"))"), "no title over the star keypoints")
        XCTAssertTrue(view.contains("Text(localized(\"\(try label("earthKeypointsTitle"))\"))"), "no title over the earth keypoints")

        // The help line is shown, and both charts can do what it says: zoom (pinch and Ctrl/Cmd+scroll), pan (drag) and click.
        XCTAssertTrue(view.contains("Text(localized(\"\(help)\"))"), "the help line is not shown")
        XCTAssertEqual(view.components(separatedBy: ".scrollWheelZoom {").count - 1, 2, "both charts zoom with the scroll wheel")
        XCTAssertEqual(view.components(separatedBy: "pan(by: value.translation.width)").count - 1, 2, "both charts pan")
        XCTAssertEqual(view.components(separatedBy: "viewModel.currentIndex = hoveredFrame").count - 1, 2, "both charts go to the clicked frame")

        defer { StarLocalization.shared.languageOverride = nil }
        StarLocalization.shared.languageOverride = "en"
        for (id, key) in labels { XCTAssertNotEqual(localized(key), key, "\(id): \(key) is missing from the catalogue") }
        let english = localized(help)
        XCTAssertNotEqual(english, help)
        StarLocalization.shared.languageOverride = "de"
        XCTAssertNotEqual(localized(help), english, "the help line is English in German")
    }
}
