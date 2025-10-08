import Foundation
import logging

/*

 - fetch releases
 - compare latest release to current version
 - return download url if version is newer
 
 */

public struct ReleaseVersion: CustomStringConvertible {

    let major: Int
    let minor: Int
    let patch: Int

    init?(_ versionString: String) {
        let components = versionString.components(separatedBy: ".")
        if components.count == 3,
           let majorVersion = Int(components[0]),
           let minorVersion = Int(components[1]),
           let patchVersion = Int(components[2])
        {
            self.major = majorVersion
            self.minor = minorVersion
            self.patch = patchVersion
        } else {
            return nil
        }
    }

    public var description: String {
        "\(major).\(minor).\(patch)"
    }
    
    public static func > (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        if lhs.major > rhs.major { return true }
        if lhs.major < rhs.major { return false }
        // major versions are equal
        if lhs.minor > rhs.minor { return true }
        if lhs.minor < rhs.minor { return false }
        // minor versions are equal
        if lhs.patch > rhs.patch { return true }

        // patch versions are equal or rhs is higher (dev build)
        return false
    }
}

public enum ReleaseType {
    case gui
    case cli
}

public func newRelease() async -> GitHubRelease? {
    let runningVersion = Config.latestVersion

    do {
        let currentRelease = try await currentRelease()
        Log.i("currentRelease \(currentRelease)")

        if let latestVersion = currentRelease.version,
           let currentVersion = ReleaseVersion(runningVersion),
           latestVersion > currentVersion
        {
            return currentRelease
        }
    } catch {
        Log.w("unable to get releases: \(error)")
    }

    return nil                  // no newer release was found
}

func currentRelease() async throws -> GitHubRelease {
    // XXX this assumes that the releases are ordered with latest first,
    // XXX which is currently the case, but may not always be
    try await fetchReleases()[0] // XXX could be better :)
}

func fetchReleases() async throws -> [GitHubRelease] {
    if let url = URL(string: "https://api.github.com/repos/brianm998/starry_timelapse_airplane_remover/releases") {
        let (data, _) = try await URLSession.shared.data(from: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([GitHubRelease].self, from: data)
    } else {
        Log.w("Unable to fetch releases because of an invalid url")
        return []
    }
}
