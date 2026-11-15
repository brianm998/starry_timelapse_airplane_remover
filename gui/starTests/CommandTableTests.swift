import XCTest
import AVFoundation
import SwiftUI
import Observation
import StarCore
import StarCppBridge
// The app target is named `Star`, not `star` — the lowercase name belongs to the .xcodeproj
// and to this test target.  TEST_HOST points at Star.app, so this is what links.
@testable import Star


/// Layer 0 of the parity plan: `gherkin/ui/commands.json` lists the menu commands both clients offer, by the catalogue key of the label.
/// The gui's menu code has to use every one (a command added to the desktop client only is a failure here), and a known gap has to
/// still be a gap.  The Kotlin client's `CommandTableTest` reads the same file.
final class CommandTableTests: XCTestCase {
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // starTests
            .deletingLastPathComponent()   // gui
            .deletingLastPathComponent()   // repo
    }

    private func table() throws -> (commands: [(id: String, label: String)], gaps: Set<String>) {
        let url = Self.repoRoot.appendingPathComponent("gherkin/ui/commands.json")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let list = try XCTUnwrap(object["commands"] as? [[String: String]])
        let gaps = (object["knownGaps"] as? [String: Any])?["gui"] as? [String: Any] ?? [:]
        return (list.map { ($0["id"] ?? "", $0["label"] ?? "") }, Set(gaps.keys))
    }

    /// Where the gui's menus are built: the commands, the app's window list, and the buttons the menus hold.
    private func menuSource() throws -> String {
        let dir = Self.repoRoot.appendingPathComponent("gui/star")
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { ($0 == "StarCommands.swift" || $0 == "StarApp.swift" || $0 == "SecondaryWindows.swift" || ($0.contains("Button") && $0.hasSuffix(".swift"))) && !$0.hasPrefix(".") }
        XCTAssertTrue(names.contains("StarCommands.swift"), "the menu source moved")
        return try names.map { try String(contentsOf: dir.appendingPathComponent($0), encoding: .utf8) }.joined(separator: "\n")
    }

    func testEveryCommandIsInTheGuisMenuOrIsAKnownGap() throws {
        let (commands, gaps) = try table()
        let source = try menuSource()
        let missing = commands.filter { !source.contains("\"\($0.label)\"") && !gaps.contains($0.id) }.map { "\($0.id) (\($0.label))" }
        XCTAssertEqual(missing, [], "menu commands the desktop client has and the gui's menu lacks")
    }

    func testAKnownGapIsStillAGap() throws {
        let (commands, gaps) = try table()
        let source = try menuSource()
        let stale = commands.filter { gaps.contains($0.id) && source.contains("\"\($0.label)\"") }.map { $0.id }
        XCTAssertEqual(stale, [], "known gaps that are closed, to be removed from commands.json")
    }

    // MARK: which menu

    private func guiFile(_ name: String) throws -> String {
        try String(contentsOf: Self.repoRoot.appendingPathComponent("gui/star/\(name)"), encoding: .utf8)
    }

    /// The text of the `{ ... }` that follows `marker`, braces matched.
    private func block(after marker: String, in text: String) throws -> String {
        let start = try XCTUnwrap(text.range(of: marker), "\(marker) is not in the source")
        let open = try XCTUnwrap(text[start.upperBound...].firstIndex(of: "{"))
        var depth = 0
        var index = open
        while index < text.endIndex {
            if text[index] == "{" { depth += 1 } else if text[index] == "}" { depth -= 1; if depth == 0 { break } }
            index = text.index(after: index)
        }
        return String(text[open...index])
    }

    private func catalogueKeys(in text: String) throws -> Set<String> {
        let pattern = try NSRegularExpression(pattern: #"localized\("([^"]+)""#)
        return Set(pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range(at: 1), in: text).map { String(text[$0]) }
        })
    }

    /// The keys a menu block uses, its own and those of the `...Button()` views it holds (a view's keys are the file it is declared in).
    private func menuKeys(_ block: String) throws -> Set<String> {
        var keys = try catalogueKeys(in: block)
        let dir = Self.repoRoot.appendingPathComponent("gui/star")
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".swift") && !$0.hasPrefix(".") }
        let named = try NSRegularExpression(pattern: #"\b([A-Z][A-Za-z]+Button)\("#)
        for match in named.matches(in: block, range: NSRange(block.startIndex..., in: block)) {
            guard let range = Range(match.range(at: 1), in: block) else { continue }
            let name = String(block[range])
            for file in files {
                let text = try guiFile(file)
                // The view's own declaration, up to the `}` in the first column that closes it: a file can hold others (a help sheet).
                if let start = text.range(of: "struct \(name)") {
                    let end = text.range(of: "\n}\n", range: start.upperBound..<text.endIndex)?.upperBound ?? text.endIndex
                    keys.formUnion(try catalogueKeys(in: String(text[start.lowerBound..<end])))
                }
            }
        }
        return keys
    }

    /// M12 / D9: each command is in the menu the table says (File, Actions, Tools, Window), and in no other.
    func testEveryCommandIsInItsMenuAndNoOther() throws {
        let commandsText = try guiFile("StarCommands.swift")
        let windowsText = try guiFile("SecondaryWindows.swift")
        let menus: [String: Set<String>] = [
            "file": try menuKeys(try block(after: "CommandGroup(replacing: .newItem)", in: commandsText))
                .union(try menuKeys(try block(after: "CommandGroup(replacing: .saveItem)", in: commandsText))),
            "actions": try menuKeys(try block(after: #"CommandMenu(localized("menu.actions"))"#, in: commandsText)),
            "tools": try menuKeys(try block(after: #"CommandMenu(localized("menu.tools"))"#, in: commandsText)),
            "window": try menuKeys(try block(after: "CommandGroup(after: .windowList)", in: windowsText)),
        ]
        let url = Self.repoRoot.appendingPathComponent("gherkin/ui/commands.json")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let (_, gaps) = try table()
        var wrong: [String] = []
        for c in try XCTUnwrap(object["commands"] as? [[String: String]]) where !gaps.contains(c["id"] ?? "") {
            let inMenus = menus.filter { $0.value.contains(c["label"] ?? "") }.keys.sorted()
            if inMenus != [c["menu"] ?? ""] { wrong.append("\(c["id"] ?? ""): in \(inMenus), expected \(c["menu"] ?? "")") }
        }
        XCTAssertEqual(wrong, [], "commands in the wrong menu")
    }

    /// The keys `StarCommands.swift` gives its menu items, spelled as `gherkin/ui/commands.json` spells them (`r`, `cmd+shift+,`).
    private func commandShortcuts(_ text: String) throws -> [String] {
        let pattern = try NSRegularExpression(pattern: #"\.keyboardShortcut\("(.)", modifiers: \[([^\]]*)\]\)"#)
        return pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { m in
            guard let k = Range(m.range(at: 1), in: text), let mods = Range(m.range(at: 2), in: text) else { return nil }
            let names = text[mods].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            let prefix = names.map { [".command": "cmd+", ".shift": "shift+", ".option": "option+"][$0] ?? "?\($0)+" }.joined()
            return prefix + text[k]
        }
    }

    /// The shortcuts of the commands and of the tools are the table's vectors: the desktop client's test holds its menu to the same file.
    func testTheShortcutsAreTheVectors() throws {
        let url = Self.repoRoot.appendingPathComponent("gherkin/ui/commands.json")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let commands = try XCTUnwrap(object["commands"] as? [[String: String]])
        let tools = try XCTUnwrap(object["toolShortcuts"] as? [[String: String]])
        let commandsText = try guiFile("StarCommands.swift")

        // Each tool item is `ChangeToolButton(tool: .x)` followed by its number key.
        let toolPattern = try NSRegularExpression(pattern: #"ChangeToolButton\(tool: \.(\w+)\)\s*\.environment\(viewModel\)\s*\.keyboardShortcut\("(\d)", modifiers: \[\]\)"#)
        let guiTools = toolPattern.matches(in: commandsText, range: NSRange(commandsText.startIndex..., in: commandsText)).compactMap { m -> [String: String]? in
            guard let t = Range(m.range(at: 1), in: commandsText), let k = Range(m.range(at: 2), in: commandsText) else { return nil }
            return ["tool": String(commandsText[t]), "shortcut": String(commandsText[k])]
        }
        XCTAssertEqual(guiTools, tools, "the Tools menu's first eight items, in order, with their number keys")

        // The window items' keys are Option plus the letter given to `item(...)`.
        let windowsText = try guiFile("SecondaryWindows.swift")
        let windowPattern = try NSRegularExpression(pattern: #"item\(\.\w+, label: localized\("[^"]+"\), shortcut: "(.)"\)"#)
        let windowKeys = windowPattern.matches(in: windowsText, range: NSRange(windowsText.startIndex..., in: windowsText)).compactMap { m in
            Range(m.range(at: 1), in: windowsText).map { "option+" + windowsText[$0] }
        }
        XCTAssertEqual(windowKeys.count, 4)
        XCTAssertTrue(try guiFile("StarCommands.swift").contains("keyboardShortcut"), "the menu source moved")
        // Play / Pause's space is on the transport button, not in the menu.
        XCTAssertTrue(try guiFile("VideoPlaybackButtons.swift").contains(#"shortcutKey: " ""#), "the space shortcut moved")

        let tableKeys = Set(commands.compactMap { $0["shortcut"] }).subtracting(["space"])
        let guiKeys = Set(try commandShortcuts(commandsText)).union(windowKeys)
        // Preferences (cmd+,) is the app menu's, not one of the table's commands.
        let toolKeys = Set(tools.compactMap { $0["shortcut"] })
        XCTAssertEqual(guiKeys.subtracting(["cmd+,"]).subtracting(toolKeys), tableKeys, "the keys the gui's menu has, and the table's")
    }

    func testTheTableIsNotEmpty() throws {
        XCTAssertGreaterThan(try table().commands.count, 20)
    }
}
