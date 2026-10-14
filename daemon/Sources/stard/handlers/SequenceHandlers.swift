import Foundation
import StarCore
import StarDaemonMessages
import SwiftProtobuf
import logging

enum SequenceHandlers {
    static func getConfig(id: UInt64, payload: Data, transport: StdioTransport, sessions: SessionManager) async {
        do {
            let req = try Star_V1_SessionRef(serializedBytes: payload)
            guard let session = await sessions.get(id: req.sessionID) else {
                await transport.sendError(id: id, message: "session not found: \(req.sessionID)", code: 404)
                return
            }
            let config = await session.configManager.config()
            try await transport.respond(id: id, payload: Mapping.protoConfig(config).serializedData())
        } catch {
            await transport.sendError(id: id, message: "\(error)")
        }
    }

    static func updateConfig(id: UInt64, payload: Data, transport: StdioTransport, sessions: SessionManager) async {
        do {
            let req = try Star_V1_UpdateConfigRequest(serializedBytes: payload)
            guard let session = await sessions.get(id: req.sessionID) else {
                await transport.sendError(id: id, message: "session not found: \(req.sessionID)", code: 404)
                return
            }
            let config = await session.updateConfig(from: req.config)
            try await transport.respond(id: id, payload: Mapping.protoConfig(config).serializedData())
        } catch {
            await transport.sendError(id: id, message: "\(error)")
        }
    }

    /// How far a previous run got, read off the disk now.  Asked once, right after a sequence is reopened from its config.
    static func getProgressSurvey(id: UInt64, payload: Data, transport: StdioTransport, sessions: SessionManager) async {
        do {
            let req = try Star_V1_SessionRef(serializedBytes: payload)
            guard let session = await sessions.get(id: req.sessionID) else {
                await transport.sendError(id: id, message: "session not found: \(req.sessionID)", code: 404)
                return
            }
            let progress = await session.surveyProgress()
            try await transport.respond(id: id, payload: StepProgressReport.proto(progress).serializedData())
        } catch {
            await transport.sendError(id: id, message: "\(error)")
        }
    }
}
