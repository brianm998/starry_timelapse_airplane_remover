import Foundation
import StarCore
import StarDaemonMessages
import logging

// Manages the [sessionId: Session] registry for the daemon.
actor SessionManager {
    private var sessions: [String: Session] = [:]
    let scratchRoot: String

    init(scratchRoot: String) {
        self.scratchRoot = scratchRoot
    }

    func add(session: Session) {
        sessions[session.sessionID] = session

        // Tell the run marker what this daemon is working on, so a daemon that gets killed
        // leaves behind a report that names the sequence rather than just a pid.
        //
        // Here rather than in the handlers because all three open paths (sequence, config,
        // video) funnel through this one call, and describing the run in three places is
        // three places to forget.
        Task {
            // Same reasoning as the gui: one daemon serves many sessions, and the output
            // write warning only fires once per run unless it is re-armed here.
            await OutputWriteFailures.shared.reset()

            let config = await session.configManager.config()
            await RunMarkerStore.shared.update(
              frameCount: await session.frameCount,
              resumeConfigPath: config.jsonPath(named: "config.json"),
              imageWidth: config.imageWidth,
              imageHeight: config.imageHeight,
              imageBytesPerPixel: config.imageBytesPerPixel
            )
            await RunMarkerStore.shared.describe(
              sequenceName: config.imageSequenceDirname,
              sequencePath: config.imageSequencePath
            )
        }
    }

    func get(id: String) -> Session? {
        sessions[id]
    }

    func remove(id: String) {
        sessions.removeValue(forKey: id)
    }

    var all: [Session] { Array(sessions.values) }

    // Generate a unique session id.
    func newSessionID() -> String {
        UUID().uuidString
    }

    // Scratch directory for a session.
    func scratchDir(for sessionID: String) -> String {
        "\(scratchRoot)/\(sessionID)"
    }
}
