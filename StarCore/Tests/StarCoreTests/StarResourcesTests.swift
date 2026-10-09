import XCTest
import Foundation
@testable import StarCore

/// `StarResources` exists because SwiftPM's `Bundle.module` falls back to the absolute build
/// directory, so a binary shipped without its resources works on the build machine and dies
/// everywhere else. These pin the part that decides where a shipped binary looks.
final class StarResourcesTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
          .appendingPathComponent("StarResourcesTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    private func makeResources(at dir: URL) throws {
        let localizations = dir.appendingPathComponent(StarLocalization.localizationsDirectoryName)
        try FileManager.default.createDirectory(at: localizations, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: localizations.appendingPathComponent("en.json"))
    }

    /// The test binary itself was built with its resources, so the real lookup must succeed —
    /// the localization tables every other test reads come through it.
    func testTheRealLookupFindsTheTables() throws {
        let root = try XCTUnwrap(StarResources.resourceRoot, "StarCore resources not found")
        XCTAssertNotNil(StarResources.url(forResource: "en", withExtension: "json",
                                          subdirectory: StarLocalization.localizationsDirectoryName),
                        "no en.json under \(root.path)")
    }

    /// Every layout a shipped binary uses is searched: `.resources` (Linux, Windows, and the
    /// desktop installers everywhere) and `.bundle` (Darwin `swift build`), each both flat and
    /// in the Contents/Resources shape an Xcode-built bundle has.
    func testCandidatesCoverEveryShippedLayout() {
        let names = StarResources.candidateDirectories().map(\.path)
        for suffix in ["StarCore_StarCore.resources",
                       "StarCore_StarCore.bundle",
                       "StarCore_StarCore.bundle/Contents/Resources"]
        {
            XCTAssertTrue(names.contains { $0.hasSuffix(suffix) }, "no candidate ending in \(suffix)")
        }
        XCTAssertEqual(names.count, Set(names).count, "candidates are not de-duplicated")
    }

    /// A directory only counts if it actually holds the tables — an empty or half-copied
    /// bundle must not shadow a good one further down the list.
    func testFirstUsableSkipsDirectoriesWithoutTheTables() throws {
        let empty = scratch.appendingPathComponent("empty.resources")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let missing = scratch.appendingPathComponent("missing.resources")
        let good = scratch.appendingPathComponent("good.resources")
        try makeResources(at: good)

        XCTAssertEqual(StarResources.firstUsable(of: [missing, empty, good])?.standardizedFileURL,
                       good.standardizedFileURL)
        XCTAssertNil(StarResources.firstUsable(of: [missing, empty]))
    }

    /// `STAR_RESOURCES_DIR` is checked before anything else.
    func testOverrideComesFirst() throws {
        let override = scratch.appendingPathComponent("override")
        try makeResources(at: override)
#if os(Windows)
        _putenv_s(StarResources.overrideEnvironmentVariable, override.path)
        defer { _putenv_s(StarResources.overrideEnvironmentVariable, "") }
#else
        setenv(StarResources.overrideEnvironmentVariable, override.path, 1)
        defer { unsetenv(StarResources.overrideEnvironmentVariable) }
#endif

        let first = try XCTUnwrap(StarResources.candidateDirectories().first)
        XCTAssertEqual(first.standardizedFileURL, override.standardizedFileURL)
        XCTAssertEqual(StarResources.firstUsable(of: StarResources.candidateDirectories())?.standardizedFileURL,
                       override.standardizedFileURL)
    }
}
