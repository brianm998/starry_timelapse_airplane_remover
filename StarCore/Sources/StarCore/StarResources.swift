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
/// executable (`swift build`, and the desktop installers), and inside an Xcode-built app's
/// Resources — and only a debug build falls back to `Bundle.module`. A release binary that finds
/// nothing logs an error and carries on without the resources (showing keys rather than
/// translations) instead of taking the engine down with it.
public enum StarResources {

    /// SwiftPM's name for StarCore's resource bundle: `<package>_<target>`.
    static let bundleName = "StarCore_StarCore"

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
        var candidates: [URL] = []

        if let override = ProcessInfo.processInfo.environment[overrideEnvironmentVariable],
           !override.isEmpty
        {
            candidates.append(URL(fileURLWithPath: override))
        }

        // Directories that could hold the bundle: beside the executable (how `swift build`
        // lays out every platform, and how the desktop installers ship stard), the main
        // bundle's own directory, and its Resources directory (an Xcode-built .app).
        var parents: [URL] = []
        if let executable = Bundle.main.executableURL {
            parents.append(executable.resolvingSymlinksInPath().deletingLastPathComponent())
        }
        if let argv0 = CommandLine.arguments.first, !argv0.isEmpty {
            parents.append(URL(fileURLWithPath: argv0).resolvingSymlinksInPath().deletingLastPathComponent())
        }
        parents.append(Bundle.main.bundleURL)
        if let resources = Bundle.main.resourceURL { parents.append(resources) }

        for parent in parents {
            // SwiftPM names it `.resources` on Linux and Windows and `.bundle` on Darwin. The
            // desktop installers use `.resources` everywhere: inside a signed macOS .app, a
            // `.bundle` directory with no Info.plist is something codesign tries to treat as
            // nested code.
            for ext in ["resources", "bundle"] {
                let dir = parent.appendingPathComponent("\(bundleName).\(ext)")
                // An Xcode-built bundle nests its files in Contents/Resources; SwiftPM's is flat.
                candidates.append(dir.appendingPathComponent("Contents").appendingPathComponent("Resources"))
                candidates.append(dir)
            }
        }
        var seen = Set<String>()
        return candidates.filter { seen.insert($0.standardizedFileURL.path).inserted }
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
