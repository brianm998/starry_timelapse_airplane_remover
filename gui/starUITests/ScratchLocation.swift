import Foundation

/// Where the UI-test runner keeps what the app under test reads and writes (input copies, `STAR_RUN_MARKER_DIR`, the `HOME` that holds
/// `.star.userprefs.json`, the processed fixture, the gallery video).
///
/// The runner (`com.star-guiUITests.xctrunner`) is sandboxed, so its `temporaryDirectory` is inside its container
/// (`~/Library/Containers/com.star-guiUITests.xctrunner/Data/tmp`). `Star.app` is not sandboxed, and an unsandboxed process that touches files in
/// another app's container makes macOS ask "“Star” would like to access data from other apps" (TCC `kTCCServiceSystemPolicyAppData`). With the
/// ad-hoc signing the pipeline and CI use the grant never sticks (the code requirement is the cdhash, which changes on every build), so the prompt
/// returns. The scratch therefore lives outside every container, and is never derived from `NSTemporaryDirectory()`.
enum ScratchLocation {
    struct Rejected: Error, CustomStringConvertible {
        let description: String
    }

    /// Set (as `TEST_RUNNER_STAR_GHERKIN_SCRATCH` to xcodebuild) to put the scratch somewhere else; it must not be inside an app container.
    static let environmentKey = "STAR_GHERKIN_SCRATCH"

    /// The per-user directory the per-run scratch directories go in.
    static func root(environment: [String: String] = ProcessInfo.processInfo.environment, uid: uid_t = getuid()) throws -> URL {
        if let override = environment[environmentKey], !override.isEmpty {
            let url = URL(fileURLWithPath: override, isDirectory: true)
            if isInsideAppContainer(url) {
                throw Rejected(description: "\(environmentKey)=\(override) is inside an app container; the app under test would cross into another app's container")
            }
            return url
        }
        return URL(fileURLWithPath: "/private/tmp/star-gherkin-\(uid)", isDirectory: true)
    }

    /// A fresh directory name (not yet created) for one run.
    static func make(environment: [String: String] = ProcessInfo.processInfo.environment, uid: uid_t = getuid()) throws -> URL {
        try root(environment: environment, uid: uid).appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    /// Whether `url` is in `~/Library/Containers/<id>/…` or `~/Library/Group Containers/…`: what App Data protection guards.
    static func isInsideAppContainer(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        return path.contains("/Library/Containers/") || path.contains("/Library/Group Containers/")
    }

    /// Creates the per-user root, owner-only, and returns it.
    @discardableResult
    static func createRoot(_ root: URL) throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return root
    }
}
