import XCTest
import AVFoundation
import SwiftUI
import Observation
import StarCore
import StarCppBridge
// The app target is named `Star`, not `star` — the lowercase name belongs to the .xcodeproj
// and to this test target.  TEST_HOST points at Star.app, so this is what links.
@testable import Star


/// D12 of the parity plan: the outlier table's decision cell toggles its group, and the columns the user chose are remembered in
/// `outlierTableColumns` (the desktop's key and column keys).
final class OutlierTableTests: XCTestCase {
    private static var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func vectorColumns() throws -> [(key: String, isDefault: Bool)] {
        let url = Self.root.appendingPathComponent("gherkin/ui/vectors/outlierColumns.json")
        let doc = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let optional = try XCTUnwrap(doc["optional"] as? [[String: Any]])
        return optional.map { ($0["key"] as! String, $0["default"] as! Bool) }
    }

    private func group() -> OutlierGroup {
        let bounds = BoundingBox(min: Coord(x: 10, y: 10), max: Coord(x: 13, y: 13))
        var pixels = [UInt16](repeating: 0, count: 16)
        var pixelSet: Set<SortablePixel> = []
        for y in 0..<4 {
            for x in 0..<4 {
                pixels[y * 4 + x] = 1000
                pixelSet.insert(SortablePixel(x: 10 + x, y: 10 + y, value: .sixteenBit(1000)))
            }
        }
        return OutlierGroup(id: 7, size: 16, brightness: 1000, bounds: bounds, frameIndex: 0,
                            imageWidth: 1000, imageHeight: 500, pixels: pixels, pixelSet: pixelSet)
    }

    /// A click on the decision cell is the click on the group with the Remove tool: undecided is removed, then it flips each time.
    func testTheDecisionCellTogglesTheGroup() async throws {
        let group = group()
        let before = await group.shouldRemove()
        XCTAssertNil(before)

        let first = await OutlierGroupTable.toggleDecision(of: group, tool: .remove)
        XCTAssertEqual(first.willRemove, true)
        let afterFirst = await group.shouldRemove()
        XCTAssertEqual(afterFirst?.willRemove, true)

        let second = await OutlierGroupTable.toggleDecision(of: group, tool: .remove)
        XCTAssertEqual(second.willRemove, false)
        let afterSecond = await group.shouldRemove()
        XCTAssertEqual(afterSecond?.willRemove, false)

        // the same rule the click on the group follows
        XCTAssertEqual(OutlierGroupView.decisionAfterClick(nil, tool: .remove).willRemove, true)
        XCTAssertEqual(OutlierGroupView.decisionAfterClick(first, tool: .remove).willRemove, false)

        // and the cell is a button that calls it, not a picture
        let source = try String(contentsOf: Self.root.appendingPathComponent("gui/star/OutlierGroupTable.swift"), encoding: .utf8)
        let column = try XCTUnwrap(source.range(of: "var willRemoveColumn"))
        let body = source[column.lowerBound...].prefix(900)
        XCTAssertTrue(body.contains("Button { toggleDecision(of: row) }"), "the decision cell has to be a button")
    }

    @MainActor
    func testColumnChoicesAreRemembered() throws {
        let vector = try vectorColumns()
        let all = vector.map { $0.key }
        let defaults = vector.filter { $0.isDefault }.map { $0.key }

        // nothing saved: the vector's defaults, and creating the model saves nothing
        var saved: [[String]] = []
        let fresh = OutlierWindowViewModel(savedColumns: nil, save: { saved.append($0) })
        XCTAssertEqual(fresh.shownColumnKeys, defaults)
        XCTAssertTrue(saved.isEmpty)

        // a saved list shows exactly those, whatever the order it was written in, and unknown keys are ignored
        let chosen = OutlierWindowViewModel(savedColumns: ["maxY", "name", "somethingNew"], save: { saved.append($0) })
        XCTAssertEqual(chosen.shownColumnKeys, ["name", "maxY"])
        XCTAssertTrue(chosen.showName)
        XCTAssertTrue(chosen.showMaxY)
        XCTAssertFalse(chosen.showWidth)
        XCTAssertTrue(saved.isEmpty)

        // one flag, in table order
        chosen.showWidth = true
        XCTAssertEqual(saved.last, ["name", "width", "maxY"])

        // Select All and Clear All write once each
        saved = []
        chosen.selectAll()
        XCTAssertEqual(saved, [all])
        chosen.clearAll()
        XCTAssertEqual(saved, [all, []])

        // an empty saved list is "none", not "the defaults"
        XCTAssertEqual(OutlierWindowViewModel(savedColumns: [], save: { _ in }).shownColumnKeys, [])
    }

    @MainActor
    func testTheColumnKeysAreTheVectors() throws {
        XCTAssertEqual(OutlierWindowViewModel.columns.map { $0.key }, try vectorColumns().map { $0.key })
        XCTAssertEqual(OutlierWindowViewModel.columns.map { $0.isDefault }, try vectorColumns().map { $0.isDefault })

        // the preference is the desktop's key, a list of strings
        // decoded rather than assigned: assigning fires the `didSet` that saves the real preferences file
        let json = Data(#"{"recentlyOpenedSequencelist":{},"outlierTableColumns":["name","width"]}"#.utf8)
        let prefs = try JSONDecoder().decode(UserPreferences.self, from: json)
        XCTAssertEqual(prefs.outlierTableColumns, ["name", "width"])
        let round = try JSONEncoder().encode(prefs)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: round) as? [String: Any])
        XCTAssertEqual(object["outlierTableColumns"] as? [String], ["name", "width"])
    }
}
