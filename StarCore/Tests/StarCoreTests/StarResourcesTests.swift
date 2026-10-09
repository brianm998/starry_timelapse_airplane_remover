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
    /// in the Contents/Resources shape an Xcode-built bundle has — and `<prefix>/share/star`
    /// for the Linux .deb and macOS pkg.
    func testCandidatesCoverEveryShippedLayout() {
        let names = StarResources.candidateDirectories().map(\.path)
        for suffix in ["StarCore_StarCore.resources",
                       "StarCore_StarCore.bundle",
                       "StarCore_StarCore.bundle/Contents/Resources",
                       "share/star/StarCore_StarCore.resources"]
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

    /// Lays out `<prefix>/bin/star`, the way the Linux .deb and the macOS pkg install it, and
    /// returns the prefix.
    private func makePrefix(named name: String = "prefix") throws -> URL {
        let prefix = scratch.appendingPathComponent(name)
        let bin = prefix.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try Data().write(to: bin.appendingPathComponent("star"))
        return prefix
    }

    /// `<prefix>/bin/star` finds `<prefix>/share/star/StarCore_StarCore.resources` — the
    /// layout the .deb installs, which keeps a folder out of /usr/local/bin.
    func testExecutableInBinFindsResourcesInShareStar() throws {
        let prefix = try makePrefix()
        let installed = prefix.appendingPathComponent("share/star/StarCore_StarCore.resources")
        try makeResources(at: installed)

        let candidates = StarResources.candidateDirectories(
          override: nil,
          executableDirectories: [prefix.appendingPathComponent("bin")],
          bundleParents: [])

        XCTAssertTrue(candidates.map(\.standardizedFileURL).contains(installed.standardizedFileURL),
                      "\(installed.path) is not a candidate")
        XCTAssertEqual(StarResources.firstUsable(of: candidates)?.standardizedFileURL,
                       installed.standardizedFileURL)
    }

    /// The same layout works when the resources came as a Darwin `.bundle` (a `swift build`
    /// tree copied over) rather than the `.resources` the installers use.
    func testShareStarAcceptsADarwinBundleName() throws {
        let prefix = try makePrefix()
        let installed = prefix.appendingPathComponent("share/star/StarCore_StarCore.bundle")
        try makeResources(at: installed)

        let candidates = StarResources.candidateDirectories(
          override: nil,
          executableDirectories: [prefix.appendingPathComponent("bin")],
          bundleParents: [])
        XCTAssertEqual(StarResources.firstUsable(of: candidates)?.standardizedFileURL,
                       installed.standardizedFileURL)
    }

    /// Resources beside the executable (a `swift build` tree, the Windows zip) win over a
    /// `share/star` install: beside-the-executable is the more specific layout.
    func testBesideTheExecutableBeatsShareStar() throws {
        let prefix = try makePrefix()
        let bin = prefix.appendingPathComponent("bin")
        let beside = bin.appendingPathComponent("StarCore_StarCore.resources")
        let shared = prefix.appendingPathComponent("share/star/StarCore_StarCore.resources")
        try makeResources(at: beside)
        try makeResources(at: shared)

        let candidates = StarResources.candidateDirectories(
          override: nil, executableDirectories: [bin], bundleParents: [])
        XCTAssertEqual(StarResources.firstUsable(of: candidates)?.standardizedFileURL,
                       beside.standardizedFileURL)
    }

    /// A `star` symlinked into /usr/local/bin from an install elsewhere is looked for beside the
    /// real file (`/opt/star/bin/star` → `/opt/star/share/star`), not beside the link.
    func testSymlinkedExecutableResolvesToItsRealPrefix() throws {
#if os(Windows)
        throw XCTSkip("creating symlinks needs a privilege the Windows runners may not have")
#else
        let prefix = try makePrefix(named: "real")
        let installed = prefix.appendingPathComponent("share/star/StarCore_StarCore.resources")
        try makeResources(at: installed)

        let links = scratch.appendingPathComponent("links")
        try FileManager.default.createDirectory(at: links, withIntermediateDirectories: true)
        let link = links.appendingPathComponent("star")
        try FileManager.default.createSymbolicLink(at: link,
                                                   withDestinationURL: prefix.appendingPathComponent("bin/star"))

        let directories = StarResources.executableDirectories(executable: link, argv0: nil)
        XCTAssertEqual(directories.map(\.standardizedFileURL),
                       [prefix.appendingPathComponent("bin").resolvingSymlinksInPath().standardizedFileURL])
        let candidates = StarResources.candidateDirectories(
          override: nil, executableDirectories: directories, bundleParents: [])
        XCTAssertEqual(StarResources.firstUsable(of: candidates)?.standardizedFileURL.resolvingSymlinksInPath(),
                       installed.resolvingSymlinksInPath().standardizedFileURL)
#endif
    }

    /// An executable with nothing installed around it finds nothing, and an empty `argv[0]`
    /// adds no directory to search.
    func testNothingInstalledFindsNothing() throws {
        let prefix = try makePrefix()
        let directories = StarResources.executableDirectories(
          executable: prefix.appendingPathComponent("bin/star"), argv0: "")
        XCTAssertEqual(directories.count, 1)
        let candidates = StarResources.candidateDirectories(
          override: nil, executableDirectories: directories, bundleParents: [])
        XCTAssertNil(StarResources.firstUsable(of: candidates))
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
