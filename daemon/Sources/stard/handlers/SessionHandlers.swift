import Foundation
import StarCore
import StarDaemonMessages
import SwiftProtobuf
import logging

enum SessionHandlers {
    static func openSequence(id: UInt64, payload: Data, transport: StdioTransport, sessions: SessionManager) async {
        do {
            let req = try Star_V1_OpenSequenceRequest(serializedBytes: payload)
            let sessionID = await sessions.newSessionID()
            let scratchDir = await sessions.scratchDir(for: sessionID)
            let session = try await Session.openSequence(
                sessionID: sessionID,
                scratchSessionDir: scratchDir,
                sequenceDir: req.sequenceDir,
                protoConfig: req.initialConfig
            )
            await sessions.add(session: session)
            let config = await session.configManager.config()
            let imageInfo = await session.imageInfo
            let frameCount = await session.frameCount
            let info = Mapping.sessionInfo(session: session, config: config, imageInfo: imageInfo, frameCount: frameCount)
            try await transport.respond(id: id, payload: info.serializedData())
        } catch {
            await transport.sendError(id: id, message: "\(error)")
        }
    }

    static func openConfig(id: UInt64, payload: Data, transport: StdioTransport, sessions: SessionManager) async {
        do {
            let req = try Star_V1_OpenConfigRequest(serializedBytes: payload)
            let sessionID = await sessions.newSessionID()
            let scratchDir = await sessions.scratchDir(for: sessionID)
            let session = try await Session.openConfig(
                sessionID: sessionID,
                scratchSessionDir: scratchDir,
                configPath: req.configJsonPath
            )
            await sessions.add(session: session)
            let config = await session.configManager.config()
            let imageInfo = await session.imageInfo
            let frameCount = await session.frameCount
            let info = Mapping.sessionInfo(session: session, config: config, imageInfo: imageInfo, frameCount: frameCount)
            try await transport.respond(id: id, payload: info.serializedData())
        } catch {
            await transport.sendError(id: id, message: "\(error)")
        }
    }

    static func openVideo(id: UInt64, payload: Data, transport: StdioTransport, sessions: SessionManager) async {
        await transport.sendError(id: id, message: "Session.OpenVideo not yet implemented (Phase 4)", code: 501)
    }

    static func close(id: UInt64, payload: Data, transport: StdioTransport, sessions: SessionManager) async {
        do {
            let req = try Star_V1_CloseSessionRequest(serializedBytes: payload)
            await sessions.remove(id: req.sessionID)
            try await transport.respond(id: id, payload: Star_V1_CloseSessionResponse().serializedData())
        } catch {
            await transport.sendError(id: id, message: "\(error)")
        }
    }

    static func list(id: UInt64, payload: Data, transport: StdioTransport, sessions: SessionManager) async {
        do {
            var resp = Star_V1_ListSessionsResponse()
            for session in await sessions.all {
                let config = await session.configManager.config()
                let imageInfo = await session.imageInfo
                let frameCount = await session.frameCount
                resp.sessions.append(Mapping.sessionInfo(session: session, config: config, imageInfo: imageInfo, frameCount: frameCount))
            }
            try await transport.respond(id: id, payload: resp.serializedData())
        } catch {
            await transport.sendError(id: id, message: "\(error)")
        }
    }
}
