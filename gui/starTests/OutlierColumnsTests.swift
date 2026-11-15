import XCTest
import AVFoundation
import SwiftUI
import Observation
import StarCore
import StarCppBridge
// The app target is named `Star`, not `star` — the lowercase name belongs to the .xcodeproj
// and to this test target.  TEST_HOST points at Star.app, so this is what links.
@testable import Star


/// Layer 0 of the parity plan (§6.2.4): the outlier table's columns are the ones `gherkin/ui/vectors/outlierColumns.json` lists, in the
/// order and with the defaults the desktop's `OutlierTable` has, and each is titled with its name in the catalogue (the headers were
/// `"id"`, `"size"`, `"remove"` and the feature's own name, English in every language).
final class OutlierColumnsTests: XCTestCase {
    override func tearDown() {
        StarLocalization.shared.languageOverride = nil
    }

    private static var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func doc() throws -> [String: Any] {
        let url = Self.root.appendingPathComponent("gherkin/ui/vectors/outlierColumns.json")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func entries(_ key: String) throws -> [[String: Any]] {
        try XCTUnwrap(try doc()[key] as? [[String: Any]])
    }

    func testTheOptionalColumnsAreTheVectorsInOrder() throws {
        let source = try String(contentsOf: Self.root.appendingPathComponent("gui/star/OutlierGroupTable.swift"), encoding: .utf8)
        let pattern = try NSRegularExpression(pattern: #"(?m)^\s*self\.tableColumn\(for: "([A-Za-z]+)""#)
        let found = pattern.matches(in: source, range: NSRange(source.startIndex..., in: source)).map {
            String(source[Range($0.range(at: 1), in: source)!])
        }
        // The id column is its own property, ahead of the decision and the size.
        XCTAssertEqual(["name"] + found, try entries("optional").map { $0["key"] as! String })
    }

    @MainActor
    func testTheColumnsShownAtFirstAreTheVectorsDefaults() throws {
        let model = OutlierWindowViewModel()
        var shown: [String: Bool] = [:]
        for child in Mirror(reflecting: model).children {
            guard let label = child.label, label.hasPrefix("_show"), let value = child.value as? Bool else { continue }
            shown[String(label.dropFirst("_show".count)).lowercased()] = value
        }
        for column in try entries("optional") {
            let key = column["key"] as! String
            XCTAssertEqual(shown[key.lowercased()], column["default"] as? Bool, "\(key)")
        }
    }

    func testEveryHeaderIsItsCatalogueName() throws {
        let columns = try entries("fixed") + entries("optional")
        for language in ["en", "de"] {
            StarLocalization.shared.languageOverride = language
            for column in columns {
                let key = column["key"] as! String
                let label = column["label"] as! String
                XCTAssertNotEqual(localized(label), label, "\(label) is missing from the catalogue")
                XCTAssertEqual(OutlierGroupTable.header(for: key), localized(label), "\(key) in \(language)")
            }
        }
        StarLocalization.shared.languageOverride = "de"
        XCTAssertEqual(OutlierGroupTable.header(for: "size"), "Größe")
        XCTAssertEqual(OutlierGroupTable.header(for: "remove"), "Entfernen")
        XCTAssertEqual(OutlierGroupTable.header(for: "classificationScore"), "Klassifikationswert")
        let source = try String(contentsOf: Self.root.appendingPathComponent("gui/star/OutlierGroupTable.swift"), encoding: .utf8)
        for literal in ["TableColumn(\"id\"", "TableColumn(\"size\"", "TableColumn(\"remove\""] {
            XCTAssertFalse(source.contains(literal), "\(literal) is a header in English")
        }
    }
}
