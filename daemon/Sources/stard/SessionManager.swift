import Foundation
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
