import Foundation

/// The daemon's answer to `GET /v1/monitor-update`: how many commits under `pipeline/monitor` the running build lacks.
/// `behind` is nil when the daemon does not know the build's commit; `latest` is the newest monitor commit on develop.
public struct MonitorUpdateInfo: Decodable, Equatable, Sendable {
    public var behind: Int?
    public var latest: String?

    public init(behind: Int?, latest: String?) {
        self.behind = behind
        self.latest = latest
    }
}

public enum MonitorUpdates {
    public static let rebuildCommand = "make -C pipeline/monitor app"

    /// The notification to deliver, and the `latest` sha to remember once it is delivered. Nil when the build is up
    /// to date, the daemon does not know the build, or this `latest` was already announced.
    public static func notification(for info: MonitorUpdateInfo, lastNotified: String?) -> (alert: Alert, latest: String)? {
        guard let behind = info.behind, behind > 0, let latest = info.latest, latest != lastNotified else { return nil }
        let commits = behind == 1 ? "1 new commit" : "\(behind) new commits"
        let alert = Alert(kind: .monitorUpdate, ticket: nil, title: "Pipeline monitor update available",
                          body: "\(commits) — run `\(rebuildCommand)`")
        return (alert, latest)
    }
}
