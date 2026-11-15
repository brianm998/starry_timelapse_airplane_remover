import XCTest
import AVFoundation
import SwiftUI
import Observation
import StarCore
import StarCppBridge
// The app target is named `Star`, not `star` — the lowercase name belongs to the .xcodeproj
// and to this test target.  TEST_HOST points at Star.app, so this is what links.
@testable import Star


/// Each setting the gui exposes is wired by hand at two places in
/// `ImageSequenceViewModel`: a loader in `init` that reads a `Config` field into the
/// property, and a `didSet` that writes the property back to a `Config` field. Nothing
/// ties those two to the same field, and getting it wrong is silent — the control would
/// display one setting and edit another, or two controls would fight over one setting.
///
/// This is the same invariant the Kotlin client's `ExpertFieldWiringTest` pins down, but it
/// has to be checked differently. There the three accessors are values in a table that a
/// test can call; here they are statements in two different scopes of a `@MainActor`
/// `@Observable` class whose init is `async throws` and needs a `ViewModel` (which kicks
/// off a release-check network call) plus a `ConfigManager`. Standing that up to set 42
/// properties would test the wiring through a great deal of unrelated machinery. The
/// pairing is a syntactic convention between two code sites, so it is checked as one.
///
/// Note that a property name is NOT required to match its field name — several
/// legitimately differ (`numberOfNeighborFrames` is backed by
/// `numberFinalProcessingNeighborsNeeded`). What must hold is that a property loads from
/// and stores to the *same* field, whatever it is called.
final class SettingsWiringTests: XCTestCase {

    // MARK: - sources under inspection

    /// gui/, derived from this file's location: gui/starTests/<this file>
    private static var guiDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source(_ relativePath: String) throws -> String {
        let url = Self.guiDir.appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func matches(_ pattern: String, in text: String) -> [[String?]] {
        guard let re = try? NSRegularExpression(pattern: pattern) else {
            XCTFail("bad pattern \(pattern)")
            return []
        }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { m in
            (0..<m.numberOfRanges).map { i in
                m.range(at: i).location == NSNotFound ? nil : ns.substring(with: m.range(at: i))
            }
        }
    }

    /// Properties whose `didSet` legitimately writes more than one `Config` field, together
    /// with the complete set of fields each one is expected to write. The pairing below
    /// matches a property to a field by finding the single field its `didSet` writes, so a
    /// second write is ordinarily a bug (two controls silently fighting over which field is
    /// "the" one) — this is the explicit exception list for the writes that are not.
    ///
    /// `primary` is the field paired against the loader (see `configLoaders`) for the other
    /// checks below; it is the field the property is actually *for*; `all` is exactly what
    /// the didSet must write, so an unexpected third write still fails loudly instead of
    /// being silently absorbed.
    ///
    /// - `alignmentKeypointDetectionDivisor` also sets `keypointDivisorWasChosen`, so the
    ///   automatic keypoint-divisor advice never overrides a value the user (or the startup
    ///   prompt) already chose explicitly — the same two-field pattern the cli uses in
    ///   `ConfigOverrides.swift` and the daemon in `Mapping.swift`. Added by 9f09e6b7.
    private struct MultiFieldWrite {
        let primary: String
        let all: Set<String>
    }
    private static let knownMultiFieldWriters: [String: MultiFieldWrite] = [
        "alignmentKeypointDetectionDivisor": MultiFieldWrite(
            primary: "alignmentKeypointDetectionDivisor",
            all: ["alignmentKeypointDetectionDivisor", "keypointDivisorWasChosen"]),
    ]

    /// property name -> the single Config field its didSet writes (or, for the properties
    /// listed in `knownMultiFieldWriters`, the primary one of several).
    private func configWriters(in source: String) -> [String: String] {
        var writers: [String: String] = [:]
        // var NAME: TYPE {  didSet {  ... realConfig.FIELD = ... } }
        let blocks = matches(#"var\s+(\w+)\s*:[^\n{]+\{\s*\n\s*didSet\s*\{([\s\S]*?)\n\s*\}\s*\n\s*\}"#,
                             in: source)
        for b in blocks {
            guard let name = b[1], let body = b[2] else { continue }
            let written = matches(#"realConfig\.(\w+)\s*="#, in: body).compactMap { $0[1] }
            guard let first = written.first else { continue }   // didSet that touches no config
            let writtenSet = Set(written)
            if let expected = Self.knownMultiFieldWriters[name] {
                XCTAssertEqual(writtenSet, expected.all,
                               "\(name): expected the documented multi-field write "
                               + "\(expected.all.sorted()), found \(writtenSet.sorted()) instead — "
                               + "update knownMultiFieldWriters if this change is intentional")
                writers[name] = expected.primary
                continue
            }
            XCTAssertEqual(writtenSet.count, 1,
                           "\(name): didSet writes more than one Config field \(writtenSet), "
                           + "which this check cannot pair unambiguously — if that is "
                           + "intentional, add \(name) to knownMultiFieldWriters")
            writers[name] = first
        }
        return writers
    }

    /// property name -> every Config field its init loader reads.
    private func configLoaders(in source: String) -> [String: Set<String>] {
        var loaders: [String: Set<String>] = [:]
        for m in matches(#"self\.(\w+)\s*=\s*[^\n]*config\.(\w+)[^\n]*"#, in: source) {
            guard let name = m[1], let field = m[2] else { continue }
            loaders[name, default: []].insert(field)
        }
        return loaders
    }

    // MARK: - the checks

    /// Guard against a vacuous pass: if the patterns above stop matching, every other test
    /// here would trivially succeed over an empty set.
    ///
    /// The floor is deliberately far below the real count (40 at the time of writing) — it is
    /// there to catch the parse breaking, not to inventory the settings.  A snug floor just
    /// fails the next time a setting is legitimately retired, which it has already done twice.
    func testTheParseFindsTheSettings() throws {
        let src = try source("star/ImageSequenceViewModel.swift")
        let writers = configWriters(in: src)
        XCTAssertGreaterThan(writers.count, 30,
                             "only found \(writers.count) config-backed properties; the "
                             + "patterns have probably stopped matching the source")
        XCTAssertFalse(configLoaders(in: src).isEmpty)
    }

    func testEveryConfigBackedPropertyLoadsFromConfig() throws {
        let src = try source("star/ImageSequenceViewModel.swift")
        let loaders = configLoaders(in: src)
        for (name, field) in configWriters(in: src) {
            XCTAssertNotNil(loaders[name],
                            "\(name) writes Config.\(field) but init never loads it from "
                            + "config, so the control opens showing a value that is not the "
                            + "config's")
        }
    }

    /// The core pairing check.
    func testWriterAndLoaderAgreeOnTheSameField() throws {
        let src = try source("star/ImageSequenceViewModel.swift")
        let loaders = configLoaders(in: src)
        for (name, written) in configWriters(in: src) {
            guard let read = loaders[name] else { continue }   // covered by the test above
            XCTAssertTrue(read.contains(written),
                          "\(name) stores to Config.\(written) but loads from "
                          + "\(read.sorted()) — it would display one setting and edit another")
        }
    }

    /// Two properties backed by one field cross-wire: editing either moves the other, and
    /// whichever saves last wins.
    func testNoTwoPropertiesWriteTheSameConfigField() throws {
        let src = try source("star/ImageSequenceViewModel.swift")
        var byField: [String: [String]] = [:]
        for (name, field) in configWriters(in: src) { byField[field, default: []].append(name) }
        for (field, names) in byField where names.count > 1 {
            XCTFail("Config.\(field) is written by \(names.sorted()) — those controls "
                    + "overwrite each other")
        }
    }

    /// FocusedField cases route keyboard focus. Two editors in one view claiming the same
    /// case send focus to the wrong box.
    func testFocusFieldsAreUniqueWithinEachView() throws {
        for view in ["star/RightPanel.swift", "star/ProcessingSettingsView.swift"] {
            let uses = matches(#"focusField:\s*\.(\w+)"#, in: try source(view)).compactMap { $0[1] }
            XCTAssertFalse(uses.isEmpty, "\(view): found no focusField uses to check")
            let dupes = Dictionary(grouping: uses, by: { $0 }).filter { $0.value.count > 1 }.keys
            XCTAssertTrue(dupes.isEmpty, "\(view): focus cases used more than once: \(Array(dupes))")
        }
    }

    /// Coverage guard for the memory settings, which are the reason this file exists. A
    /// reservation knob that is not reachable from the gui is the state this campaign has
    /// been undoing; this fails if one is dropped from the settings view.
    func testMemorySettingsAreReachableFromTheSettingsView() throws {
        let settings = try source("star/ProcessingSettingsView.swift")
        let viewModel = try source("star/ImageSequenceViewModel.swift")
        let expected = [
          "keypointMemoryMultiplier",
          "outlierMemoryMultiplier",
          "mergeMemoryMultiplier",
          "horizonMemoryMultiplier",
          "horizonReservationFloorMB",
          "alignmentKeypointDetectionDivisor",
        ]
        for name in expected {
            XCTAssertTrue(settings.contains("viewModel.\(name)"),
                          "\(name) is not bound in ProcessingSettingsView")
            XCTAssertTrue(viewModel.contains("var \(name)"),
                          "\(name) is not a property on ImageSequenceViewModel")
        }
    }
}
