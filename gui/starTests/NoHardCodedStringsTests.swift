import XCTest
import AVFoundation
import SwiftUI
import Observation
import StarCore
import StarCppBridge
// The app target is named `Star`, not `star` — the lowercase name belongs to the .xcodeproj
// and to this test target.  TEST_HOST points at Star.app, so this is what links.
@testable import Star


/// I1 of `plans/GUI_CLIENT_PARITY_PLAN.md`: nothing the gui says is written into its code.  Every word on screen is a catalogue key
/// looked up with `localized(...)`, so that it follows the language the user picked.  This is the counterpart of the Kotlin client's
/// `NoHardCodedStringsTest`: it reads the sources under `gui/star` and fails on a string literal handed to a call that puts text on
/// screen (`Text(`, `Label(`, `Button(`, `.help(`, `.navigationTitle(` …) that reads as something shown to a person: it starts with a
/// capital, or has a word, a space and another word.  Keys, symbol names and identifiers are not prose and pass.
final class NoHardCodedStringsTests: XCTestCase {

    /// "file:literal" -> why it may stay.
    private static let allowed: [String: String] = [:]

    private static var starDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("star")
    }

    /// The calls that put text on screen.
    private static let sink = try! NSRegularExpression(
        pattern: #"(?:\b(?:Text|Label|Button|Toggle|Picker|Section|TextField|GroupBox|Menu|DisclosureGroup)\(|\.(?:help|navigationTitle|accessibilityLabel|alert|confirmationDialog)\()"#)
    private static let literal = try! NSRegularExpression(pattern: #""((?:[^"\\\n]|\\.)*)""#)
    private static let symbolArgument = try! NSRegularExpression(
        pattern: #"(?:systemImage|image|named|id|identifier|name):\s*"[^"]*""#)

    /// The source with comments blanked out, line breaks kept, so a quoted word in a comment is not a literal.
    static func withoutComments(_ source: String) -> String {
        let chars = Array(source)
        var out = [Character]()
        var i = 0
        while i < chars.count {
            if i + 2 < chars.count, chars[i] == "\"", chars[i + 1] == "\"", chars[i + 2] == "\"" {
                var j = i + 3
                while j + 2 < chars.count, !(chars[j] == "\"" && chars[j + 1] == "\"" && chars[j + 2] == "\"") { j += 1 }
                let end = min(j + 3, chars.count)
                out.append(contentsOf: chars[i..<end]); i = end
            } else if chars[i] == "\"" {
                var j = i + 1
                while j < chars.count, chars[j] != "\"", chars[j] != "\n" {
                    if chars[j] == "\\" { j += 1 }
                    j += 1
                }
                let end = min(j + 1, chars.count)
                out.append(contentsOf: chars[i..<end]); i = end
            } else if i + 1 < chars.count, chars[i] == "/", chars[i + 1] == "/" {
                var j = i
                while j < chars.count, chars[j] != "\n" { out.append(" "); j += 1 }
                i = j
            } else if i + 1 < chars.count, chars[i] == "/", chars[i + 1] == "*" {
                var j = i + 2
                while j + 1 < chars.count, !(chars[j] == "*" && chars[j + 1] == "/") { j += 1 }
                let end = min(j + 2, chars.count)
                for c in chars[i..<end] { out.append(c == "\n" ? "\n" : " ") }
                i = end
            } else {
                out.append(chars[i]); i += 1
            }
        }
        return String(out)
    }

    /// The index of the `)` that closes the `(` at `open`, skipping string literals and what is interpolated into them.
    static func closingParenthesis(in chars: [Character], from open: Int) -> Int {
        var depth = 0
        var j = open
        while j < chars.count {
            let c = chars[j]
            if c == "\"" {
                j += 1
                while j < chars.count, chars[j] != "\"", chars[j] != "\n" {
                    if chars[j] == "\\" {
                        if j + 1 < chars.count, chars[j + 1] == "(" {
                            var k = j + 2, d = 1
                            while k < chars.count, d > 0 {
                                if chars[k] == "(" { d += 1 } else if chars[k] == ")" { d -= 1 }
                                k += 1
                            }
                            j = k
                            continue
                        }
                        j += 1
                    }
                    j += 1
                }
            } else if c == "(" {
                depth += 1
            } else if c == ")" {
                depth -= 1
                if depth == 0 { return j }
            }
            j += 1
        }
        return chars.count
    }

    /// What is left of a literal once the values interpolated into it are taken out: the words that are written down.
    static func words(_ text: String) -> String {
        text.replacingOccurrences(of: #"\\\([^)]*\)"#, with: "", options: .regularExpression)
    }

    static func looksLikeProse(_ text: String) -> Bool {
        let w = words(text)
        guard w.range(of: "[A-Za-z]{2}", options: .regularExpression) != nil else { return false }
        if w.range(of: "^[A-Z_0-9]+$", options: .regularExpression) != nil { return false }
        return w.range(of: "^[A-Z][a-z]", options: .regularExpression) != nil
            || w.range(of: #"[A-Za-z]\s+[A-Za-z]"#, options: .regularExpression) != nil
    }

    /// Every prose literal handed to a call that puts text on screen, in `source`.
    static func hardCodedStrings(in source: String) -> [String] {
        let text = withoutComments(source)
        let chars = Array(text)
        let ns = text as NSString
        var found: [String] = []
        for m in sink.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            // NSString offsets are UTF-16, `chars` are characters: both are the same for the ASCII that holds a call.
            let open = m.range.location + m.range.length - 1
            guard open < chars.count else { continue }
            let close = closingParenthesis(in: chars, from: open)
            var argument = String(chars[(open + 1)..<min(close, chars.count)])
            argument = symbolArgument.stringByReplacingMatches(
                in: argument, range: NSRange(location: 0, length: (argument as NSString).length), withTemplate: "")
            // a `localized(...)` call is a key, whatever it is spelled like
            argument = argument.replacingOccurrences(
                of: #"localized\((?:[^()]|\([^()]*\))*\)"#, with: "", options: .regularExpression)
            let a = argument as NSString
            for l in literal.matches(in: argument, range: NSRange(location: 0, length: a.length)) {
                let value = a.substring(with: l.range(at: 1))
                if looksLikeProse(value) { found.append(value) }
            }
        }
        return found
    }

    func testNoScreenWritesItsWordsInCode() throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: Self.starDir.path)
            .filter { $0.hasSuffix(".swift") && !$0.hasPrefix(".") }
        XCTAssertGreaterThan(names.count, 20, "found only \(names.count) sources in gui/star")
        var problems: [String] = []
        for name in names.sorted() {
            let source = try String(contentsOf: Self.starDir.appendingPathComponent(name), encoding: .utf8)
            for value in Self.hardCodedStrings(in: source) where Self.allowed["\(name):\(value)"] == nil {
                problems.append("\(name): \"\(value)\"")
            }
        }
        XCTAssertTrue(problems.isEmpty,
                      "text written into the code instead of the catalogue (add a key to every table and call localized):\n"
                      + problems.joined(separator: "\n"))
    }

    // MARK: - the scanner itself

    func testItFindsALiteralHandedToText() {
        XCTAssertEqual(Self.hardCodedStrings(in: #"Text("Process all frames")"#), ["Process all frames"])
    }

    func testItFindsOneInATernary() {
        XCTAssertEqual(Self.hardCodedStrings(in: #"Label(hasMore ? "Next" : "Continue", systemImage: "checkmark.circle.fill")"#),
                       ["Next", "Continue"])
    }

    func testItFindsOneWithAnInterpolation() {
        XCTAssertEqual(Self.hardCodedStrings(in: #"Label("Process \(label) (new only)", systemImage: "play.circle")"#),
                       [#"Process \(label) (new only)"#])
    }

    func testAKeyASymbolAndAnIdentifierAreNotProse() {
        XCTAssertEqual(Self.hardCodedStrings(in: #"""
            Text(localized("ui.save_reference_horizon"))
            Label(localized(hasMore ? "ui.next" : "ui.continue"), systemImage: "checkmark.circle.fill")
            Button(action: go) { Image(systemName: "play.fill") }
              .accessibilityIdentifier("render.all.frames")
            """#), [])
    }

    func testACommentIsNotALiteral() {
        XCTAssertEqual(Self.hardCodedStrings(in: #"// Text("Process all frames")"#), [])
    }
}
