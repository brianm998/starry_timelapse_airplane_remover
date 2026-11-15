import XCTest
import AVFoundation
import SwiftUI
import Observation
import StarCore
import StarCppBridge
// The app target is named `Star`, not `star` — the lowercase name belongs to the .xcodeproj
// and to this test target.  TEST_HOST points at Star.app, so this is what links.
@testable import Star


/// `UserPreferences` is a value type whose every field writes the *whole* file on change, so a
/// second copy of it is a second writer: whichever copy saves last puts its own version of every
/// other field back on disk.  `ViewModel` and `ImageSequenceViewModel` each held one, synced only
/// when a sequence was opened, so a render setting changed in the render sheet (written through
/// the sequence's copy) was undone the next time anything wrote through the app's copy — opening
/// another sequence was enough, since that writes the recent-files list.
///
/// The fix is that there is now one live copy, in `UserPreferencesStore`, and both view models
/// expose `userPreferences` as a view onto it.  That is a shape rather than a behaviour, and the
/// objects that would demonstrate it cannot be stood up in a test: `ViewModel.init` reads the
/// real preferences file and prunes it (writing it back), and `ImageSequenceViewModel`'s init is
/// `async throws` over a `ConfigManager`.  So it is checked the way `SettingsWiringTests` checks
/// its own two-site convention — over the source.
@MainActor
final class UserPreferencesStoreTests: XCTestCase {

    /// gui/, derived from this file's location: gui/starTests/<this file>
    private static var guiDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: Self.guiDir.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func swiftSources() throws -> [(name: String, text: String)] {
        let dir = Self.guiDir.appendingPathComponent("star")
        // Dotfiles are skipped, not just hidden clutter: an Emacs lock file is named
        // `.#Foo.swift` and is a dangling symlink (its target is `user@host.pid:boot`, not a
        // path), so it passes a bare `.swift` filter and then fails to read.  Anyone with the
        // project open in an editor that writes lock files would see these tests fail.
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasSuffix(".swift") && !$0.hasPrefix(".") }
        XCTAssertGreaterThan(names.count, 20, "found only \(names.count) sources in gui/star")
        return try names.map { ($0, try source("star/\($0)")) }
    }

    /// The whole `var userPreferences: UserPreferences { ... }` declaration, accessors included.
    private func accessor(in source: String) -> String? {
        let pattern = #"var\s+userPreferences\s*:\s*UserPreferences\s*(\{[\s\S]*?\n    \})"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = source as NSString
        guard let m = re.firstMatch(in: source, range: NSRange(location: 0, length: ns.length))
        else { return nil }
        return ns.substring(with: m.range(at: 1))
    }

    // MARK: - one live copy

    /// A stored `userPreferences` on either view model is the hazard itself.
    func testNeitherViewModelKeepsItsOwnCopy() throws {
        for file in ["star/ViewModel.swift", "star/ImageSequenceViewModel.swift"] {
            let src = try source(file)
            XCTAssertFalse(src.contains("var userPreferences: UserPreferences ="),
                           "\(file) stores its own copy of the preferences again")

            let block = try XCTUnwrap(accessor(in: src), "\(file) has no userPreferences accessor")
            XCTAssertTrue(block.contains("UserPreferencesStore.shared.preferences"),
                          "\(file) reads preferences from somewhere other than the store: \(block)")
            XCTAssertTrue(block.contains("UserPreferencesStore.shared.preferences = newValue"),
                          "\(file) writes preferences somewhere other than the store: \(block)")
        }
    }

    /// Constructing one anywhere else makes a second value that can be written and saved.
    func testOnlyTheStoreConstructsAUserPreferences() throws {
        var built: [String] = []
        for file in try swiftSources() {
            // (?<!\w) so that applyUserPreferences() and the like do not match
            if let re = try? NSRegularExpression(pattern: #"(?<![A-Za-z0-9_])UserPreferences\("#) {
                let ns = file.text as NSString
                let n = re.numberOfMatches(in: file.text,
                                           range: NSRange(location: 0, length: ns.length))
                if n > 0 { built.append("\(file.name) ×\(n)") }
            }
        }
        XCTAssertEqual(built, ["UserPreferences.swift ×1"],
                       "a UserPreferences is built outside the store: \(built)")
    }

    /// The App Sandbox denies writes to `/tmp` and moves `$HOME` into the container, so no source builds either path by hand: the
    /// home directory comes from `NSHomeDirectory()` (which follows the sandbox) and scratch files go in the temporary directory.
    /// The one exception is `UserPreferences.path`, which reads `$HOME` only when the process is not sandboxed: `NSHomeDirectory()` ignores a
    /// `$HOME` override, and the UI-test runner launches the app with one to keep it off the real preferences.
    func testNoHandBuiltTmpOrHomePathsInSources() throws {
        let sources = Self.guiDir.deletingLastPathComponent().appendingPathComponent("StarCore/Sources")
        var urls = try swiftSources().map { Self.guiDir.appendingPathComponent("star/\($0.name)") }
        let walker = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        for case let url as URL in walker where url.pathExtension == "swift" && !url.lastPathComponent.hasPrefix(".") {
            urls.append(url)
        }
        XCTAssertGreaterThan(urls.count, 100, "found only \(urls.count) sources")

        let handBuilt = try NSRegularExpression(pattern: #""/tmp|environment\["HOME"\]|env\["HOME"\]"#)
        var found: [String] = []
        for url in urls where url.lastPathComponent != "UserPreferences.swift" {
            let text = NoHardCodedStringsTests.withoutComments(try String(contentsOf: url, encoding: .utf8))
            let n = handBuilt.numberOfMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
            if n > 0 { found.append("\(url.lastPathComponent) ×\(n)") }
        }
        XCTAssertEqual(found, [], "a /tmp or $HOME path is built by hand: \(found)")
    }

    /// The tell of the old hazard: reaching through one view model to write the preferences held
    /// by the other, which is what had to be done, field by field, to keep them in step.
    func testNoPreferenceIsWrittenThroughASecondViewModel() throws {
        // over whitespace-collapsed source, not line by line: the one that used to be here was
        // wrapped, with the receiver on one line and `.userPreferences` on the next
        let reachThrough = #"(imageSequence\?|topViewModel\?|imageSequenceViewModel)\s*\.\s*userPreferences"#
        let re = try NSRegularExpression(pattern: reachThrough)

        var doubleWrites: [String] = []
        for file in try swiftSources() {
            let flat = file.text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            let ns = flat as NSString
            for m in re.matches(in: flat, range: NSRange(location: 0, length: ns.length)) {
                let from = max(0, m.range.location - 20)
                let length = min(ns.length - from, m.range.length + 60)
                doubleWrites.append("\(file.name): …\(ns.substring(with: NSRange(location: from, length: length)))…")
            }
        }
        XCTAssertEqual(doubleWrites, [],
                       "preferences written through a second view model — the single store makes "
                       + "this unnecessary, and it is how the two copies drifted: \(doubleWrites)")
    }

    // MARK: - what the sequence's view model still has to do

    /// The stored property's `didSet` used to seed the video settings from the preferences on
    /// every write; the setter has to keep doing it, or changing the frame rate in the render
    /// sheet would no longer reach the settings the render actually uses.
    func testWritingPreferencesStillSeedsTheSequenceSettings() throws {
        let src = try source("star/ImageSequenceViewModel.swift")
        let block = try XCTUnwrap(accessor(in: src))
        XCTAssertTrue(block.contains("applyUserPreferences()"),
                      "the setter no longer re-applies the preferences: \(block)")

        for setting in ["frameRate", "codec", "encoder", "pixelFormat", "muxer"] {
            XCTAssertTrue(src.contains("self.\(setting) = \(setting)"),
                          "applyUserPreferences no longer seeds \(setting)")
        }
    }

    /// L2 of the parity plan: the detection type is the sequence's own, from its `config.json`.  The preference only seeds a *new*
    /// sequence (its `Config` is built with it), so a write to any preference must not push it into the one that is open.
    func testTheDetectionTypeIsTheSequencesOwnAndThePreferenceOnlySeedsANewOne() throws {
        let src = try source("star/ImageSequenceViewModel.swift")
        XCTAssertFalse(src.contains("self.detectionType = detectionType"),
                       "a preference write overwrites the open sequence's detection type again")
        XCTAssertTrue(src.contains("self.detectionType = config.detectionType"),
                      "a sequence no longer reads its detection type from its config")
        XCTAssertTrue(src.contains("detectionType: UserPreferencesStore.shared.preferences.processingType ?? .strong"),
                      "a new sequence is no longer seeded from the preference")
    }

    /// The GPU toggles are remembered across sequences by two halves that have to stay in step,
    /// and neither can be run here (a sequence's view model cannot be stood up in a test): a
    /// toggle changed in the settings sheet is written to the preferences, and a sequence being
    /// opened is seeded from them.  Lose the first and a choice is forgotten the moment the
    /// sequence closes; lose the second and it is remembered but never used.
    func testTheGPUTogglesAreRememberedAndSeededBack() throws {
        let src = try source("star/ImageSequenceViewModel.swift")
        let flat = src.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        for name in ["Merge", "SIFT", "AKAZE"] {
            // written when the toggle changes …
            XCTAssertTrue(flat.contains("userPreferences.useGPUFor\(name) = useGPUFor\(name)"),
                          "changing useGPUFor\(name) no longer reaches the preferences")
            // … and put back on a sequence when it is opened, or the preferences are written
            XCTAssertTrue(flat.contains("if let useGPUFor\(name) = userPreferences.useGPUFor\(name)"),
                          "applyUserPreferences no longer seeds useGPUFor\(name)")
        }
    }

    /// A sequence opens with its settings at their defaults, so `ViewModel` has to seed them —
    /// that was the one thing the copy-down assignment did that was not just copying.
    func testOpeningASequenceAppliesThePreferencesToIt() throws {
        let src = try source("star/ViewModel.swift")
        let opens = src.components(separatedBy: "imageSequence = imageSequenceViewModel").count - 1
        XCTAssertEqual(opens, 3, "the number of ways a sequence is opened has changed")
        XCTAssertEqual(src.components(separatedBy: "imageSequenceViewModel.applyUserPreferences()").count - 1,
                       opens, "not every sequence-open applies the preferences to the new sequence")
    }

    // MARK: - the store itself

    /// Holding the value rather than vending copies of it is the whole point.  Assigning a whole
    /// struct does not touch the file — only the individual field setters save — so this cannot
    /// disturb the preferences of whoever runs it; the original is put back regardless.
    func testTheStoreHoldsTheValueEveryReaderSees() throws {
        let store = UserPreferencesStore.shared
        let original = store.preferences
        defer { store.preferences = original }

        let json = #"{"recentlyOpenedSequencelist":{},"movingHorizonCountMultiplier":3.25}"#
        store.preferences = try JSONDecoder().decode(UserPreferences.self, from: Data(json.utf8))

        XCTAssertEqual(UserPreferencesStore.shared.preferences.movingHorizonCountMultiplier, 3.25)
        XCTAssertTrue(UserPreferencesStore.shared === store, "the store is not a singleton")
    }

    private final class Flag: @unchecked Sendable { var raised = false }

    /// Every view that reads a preference used to read it from an `@Observable` view model, so a
    /// change redrew it.  Now the value lives a level further away, and the redraw depends on the
    /// store being observable too — silently, since nothing fails to compile if it is not.
    func testChangingAPreferenceStillNotifiesTheViewsThatReadIt() throws {
        let store = UserPreferencesStore.shared
        let original = store.preferences
        defer { store.preferences = original }

        let fired = Flag()
        withObservationTracking {
            _ = store.preferences.movingHorizonCountMultiplier
        } onChange: {
            fired.raised = true
        }
        XCTAssertFalse(fired.raised, "notified before anything changed")

        let json = #"{"recentlyOpenedSequencelist":{},"movingHorizonCountMultiplier":4.5}"#
        store.preferences = try JSONDecoder().decode(UserPreferences.self, from: Data(json.utf8))

        XCTAssertTrue(fired.raised,
                      "a preference changed without notifying its readers — views that show one "
                      + "would no longer redraw")
    }
}
