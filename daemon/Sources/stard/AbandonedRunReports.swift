import Foundation
import StarCore

/// What a daemon that was killed left behind, held until there is somebody to tell.
///
/// The daemon finds these as it starts, before it has a transport and before it has been told what language its client shows, and the prose
/// of a report is localized when it is written: so the markers are kept as they are and turned into warnings by the first `Daemon.Hello`,
/// which is when both are known, and sent as `Star.Warning` notifications. Once only: a second Hello (it is idempotent) finds nothing.
actor AbandonedRunReports {
    static let shared = AbandonedRunReports()

    private var markers: [RunMarker] = []

    func store(_ found: [RunMarker]) { markers = found }

    /// The reports, and forgets them.
    func take() -> [RunMarker] {
        defer { markers = [] }
        return markers
    }

    /// A report of a run that died, as the warning a client shows and the config it could restart the run from (nil when the config has gone: a
    /// restart offered over a file that is not there fails after the click, which is worse than not offering).
    static func report(for marker: RunMarker) -> (warning: StarWarning, restartableConfigPath: String?) {
        (marker.asWarning, marker.restartableConfigPath)
    }
}
