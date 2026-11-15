import XCTest
import AVFoundation
import SwiftUI
import Observation
import StarCore
import StarCppBridge
// The app target is named `Star`, not `star` — the lowercase name belongs to the .xcodeproj
// and to this test target.  TEST_HOST points at Star.app, so this is what links.
@testable import Star


/// Layer 0 (plan §6.2.1): the identifiers a UI step may use, `gherkin/ui/ids.json`, against what `gui/star` carries as
/// id-shaped literals. The desktop's `IdRegistryTest` scans `star-desktop/src/main` against the same file.
final class IdRegistryTests: XCTestCase {
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // starTests
            .deletingLastPathComponent()   // gui
            .deletingLastPathComponent()   // repo
    }

    private func registry() throws -> (ids: [String], gaps: Set<String>, otherGaps: Set<String>) {
        let url = Self.repoRoot.appendingPathComponent("gherkin/ui/ids.json")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let gaps = try XCTUnwrap(object["knownGaps"] as? [String: [String: String]])
        return (try XCTUnwrap(object["ids"] as? [String]), Set(gaps["gui"]?.keys ?? [:].keys), Set(gaps["desktop"]?.keys ?? [:].keys))
    }

    /// The first segment of every id the registry lists: the namespaces the scan looks for.
    private func namespaces() throws -> Set<String> {
        let (ids, guiGaps, desktopGaps) = try registry()
        return Set((ids + Array(guiGaps) + Array(desktopGaps)).compactMap { $0.split(separator: ".").first.map(String.init) })
    }

    /// Every string literal in `gui/star` shaped like an id in one of those namespaces, so an id handed to a helper that tags the control
    /// is seen as well as one written at `.accessibilityIdentifier("...")`.
    private func found() throws -> Set<String> {
        let dir = Self.repoRoot.appendingPathComponent("gui/star")
        let names = try namespaces().sorted().joined(separator: "|")
        let pattern = try NSRegularExpression(pattern: "\"((?:\(names))\\.[a-z0-9_.]*[a-z0-9_*])\"")
        var ids = Set<String>()
        for name in try FileManager.default.contentsOfDirectory(atPath: dir.path) where name.hasSuffix(".swift") && !name.hasPrefix(".") {
            let text = try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
            for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                if let range = Range(match.range(at: 1), in: text) { ids.insert(String(text[range])) }
            }
        }
        return ids
    }

    /// An entry covers an id when they are equal or the entry is a `prefix*` family the id falls in.
    private func covers(_ entry: String, _ id: String) -> Bool {
        entry.hasSuffix("*") ? id.hasPrefix(String(entry.dropLast())) : entry == id
    }

    func testEveryIdBothClientsCarryIsHere() throws {
        let (ids, _, _) = try registry()
        let found = try found()
        let missing = ids.filter { entry in !found.contains { covers(entry, $0) } }
        XCTAssertEqual(missing, [], "ids the desktop has and the gui lacks: add them, or list them in knownGaps.gui")
    }

    func testEveryIdTheGuiCarriesIsRegistered() throws {
        let (ids, guiGaps, desktopGaps) = try registry()
        let found = try found()
        let known = ids + Array(guiGaps) + Array(desktopGaps)
        let unregistered = found.filter { id in !known.contains { covers($0, id) } }.sorted()
        XCTAssertEqual(unregistered, [], "ids the gui carries that gherkin/ui/ids.json does not list")
    }

    func testAGapTheGuiHasClosedIsRemoved() throws {
        let (_, guiGaps, desktopGaps) = try registry()
        let found = try found()
        XCTAssertEqual(guiGaps.filter { gap in found.contains { covers(gap, $0) } }.sorted(), [], "knownGaps.gui entries the gui now has")
        XCTAssertEqual(desktopGaps.filter { gap in !found.contains { covers(gap, $0) } }.sorted(), [],
                       "knownGaps.desktop entries the gui does not have either: they are not gaps of the desktop's alone")
    }
}
