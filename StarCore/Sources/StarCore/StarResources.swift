import Foundation
import logging

/*

This file is part of the Starry Timelapse Airplane Remover (star).

star is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

star is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with star. If not, see <https://www.gnu.org/licenses/>.

*/

/// Where StarCore's own resources (the localization tables, the tile classifier) live at runtime.
///
/// ## Why not just `Bundle.module`
///
/// SwiftPM's generated `Bundle.module` looks in exactly two places — beside the executable, and
/// the absolute path of the build directory it was compiled in — and calls `fatalError` if
/// neither exists. The second path is what made a missing resource folder invisible: on the
/// machine that built the binary, including every CI runner, the build directory is still there,
/// so a binary shipped *without* its resources works perfectly in every test and then dies on a
/// user's machine the first time anything is localized. That is exactly what the Windows desktop
/// build did: `stard.exe` was installed without `StarCore_StarCore.resources`, and the very first
/// request, `Daemon.Hello`, sets the language and so read a table — so the engine died straight
/// after "connecting", every time, on every machine but the one that built it.
///
/// So the lookup here searches the places a *shipped* binary keeps its resources — beside the
/// executable (`swift build`, the Windows CLI zip/installer and the desktop installers), in
/// `<prefix>/share/star` when the executable is in `<prefix>/bin` (the Linux .deb and the macOS
/// pkg, which would rather not put a folder in `/usr/local/bin`), and inside an Xcode-built app's
/// Resources — and only a debug build falls back to `Bundle.module`. A release binary that finds
/// nothing logs an error and carries on without the resources (showing keys rather than
/// translations) instead of taking the engine down with it.
public enum StarResources {

    /// SwiftPM's name for StarCore's resource bundle: `<package>_<target>`.
    static let bundleName = "StarCore_StarCore"

    /// Where, relative to `<prefix>` of `<prefix>/bin/<executable>`, an installed copy keeps the
    /// resources: `<prefix>/share/star/StarCore_StarCore.resources`.
    static let shareDirectoryComponents = ["share", "star"]

    /// Lets an unusual install point at the resources explicitly.
    static let overrideEnvironmentVariable = "STAR_RESOURCES_DIR"

    /// The directory holding StarCore's resources (`Localizations/`, `tile_classifier.mlmodelc`),
    /// or nil if no copy could be found.
    public static let resourceRoot: URL? = locate()

    /// A resource inside ``resourceRoot``, if it exists.
    public static func url(forResource name: String,
                           withExtension ext: String,
                           subdirectory: String? = nil) -> URL?
    {
        guard let root = resourceRoot else { return nil }
        var url = root
        if let subdirectory { url = url.appendingPathComponent(subdirectory) }
        url = url.appendingPathComponent("\(name).\(ext)")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Every directory a shipped binary might keep its resources in, most specific first.
    static func candidateDirectories() -> [URL] {
        // Directories that could hold the bundle beside something: the main bundle's own
        // directory, and its Resources directory (an Xcode-built .app).
        var bundleParents: [URL] = [Bundle.main.bundleURL]
        if let resources = Bundle.main.resourceURL { bundleParents.append(resources) }

        return candidateDirectories(
          override: ProcessInfo.processInfo.environment[overrideEnvironmentVariable],
          executableDirectories: executableDirectories(executable: Bundle.main.executableURL,
                                                       argv0: CommandLine.arguments.first),
          bundleParents: bundleParents)
    }

    /// The directories the running executable lives in, with symlinks resolved: a `star` linked
    /// into `/usr/local/bin` from elsewhere keeps its resources beside the real file, not the link.
    /// `Bundle.main` and `argv[0]` can disagree (and either can be missing), so both are used.
    static func executableDirectories(executable: URL?, argv0: String?) -> [URL] {
        var directories: [URL] = []
        if let executable {
            directories.append(executable.resolvingSymlinksInPath().deletingLastPathComponent())
        }
        if let argv0, !argv0.isEmpty {
            directories.append(URL(fileURLWithPath: argv0).resolvingSymlinksInPath().deletingLastPathComponent())
        }
        return directories
    }

    /// The search order itself, separated from the process it is searching on behalf of so a
    /// test can lay out an install in a scratch directory and ask where it would be found.
    ///
    /// - Parameters:
    ///   - override: the `STAR_RESOURCES_DIR` value, if set.
    ///   - executableDirectories: where the running executable lives.
    ///   - bundleParents: the main bundle's directory and its Resources directory.
    static func candidateDirectories(override: String?,
                                     executableDirectories: [URL],
                                     bundleParents: [URL]) -> [URL]
    {
        var candidates: [URL] = []

        if let override, !override.isEmpty {
            candidates.append(URL(fileURLWithPath: override))
        }

        // Beside the executable (how `swift build` lays out every platform, and how the Windows
        // CLI package and the desktop installers ship it), then beside the main bundle.
        for parent in executableDirectories + bundleParents {
            candidates.append(contentsOf: bundleLocations(in: parent))
        }

        // <prefix>/share/star for an executable in <prefix>/bin: the Unix layout the Linux .deb
        // and the macOS pkg install to, so /usr/local/bin holds only the program. Last, because
        // anything laid out beside the executable is more specific than a shared directory.
        for directory in executableDirectories {
            var share = directory.deletingLastPathComponent()
            for component in shareDirectoryComponents { share.appendPathComponent(component) }
            candidates.append(contentsOf: bundleLocations(in: share))
        }

        var seen = Set<String>()
        return candidates.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    /// Where StarCore's resource bundle could be inside `parent`.
    private static func bundleLocations(in parent: URL) -> [URL] {
        var locations: [URL] = []
        // SwiftPM names it `.resources` on Linux and Windows and `.bundle` on Darwin. The
        // installers use `.resources` everywhere: inside a signed macOS .app, a `.bundle`
        // directory with no Info.plist is something codesign tries to treat as nested code,
        // and in a pkg anything with an Info.plist becomes a version-checked bundle component.
        for ext in ["resources", "bundle"] {
            let dir = parent.appendingPathComponent("\(bundleName).\(ext)")
            // An Xcode-built bundle nests its files in Contents/Resources; SwiftPM's is flat.
            locations.append(dir.appendingPathComponent("Contents").appendingPathComponent("Resources"))
            locations.append(dir)
        }
        return locations
    }

    /// The first candidate that actually holds StarCore's resources.
    static func firstUsable(of candidates: [URL]) -> URL? {
        for dir in candidates {
            // Localizations/ is in every build; the tile classifier only matters on Darwin.
            let marker = dir.appendingPathComponent(StarLocalization.localizationsDirectoryName)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: marker.path, isDirectory: &isDirectory),
               isDirectory.boolValue
            {
                return dir
            }
        }
        return nil
    }

    private static func locate() -> URL? {
        let candidates = candidateDirectories()
        if let found = firstUsable(of: candidates) { return found }

#if DEBUG
        // Development builds and tests need the build-directory fallback: an xctest runner is
        // not beside the bundle. This can still `fatalError` if there is truly nothing — which
        // in a debug build means a broken checkout, not a user's install.
        return Bundle.module.resourceURL
#else
        Log.e("StarCore resources (\(bundleName)) not found — localized text will show keys. " +
              "Looked in: " + candidates.map(\.path).joined(separator: ", "))
        return nil
#endif
    }
}
