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
            var config = await session.configManager.config()
            let proto = req.config
            config.cleanMethod = Mapping.cleanMethod(from: proto)
            config.detectionType = Mapping.detectionType(from: proto.detectionType)
            config.horizonDetectionEnabled = proto.horizonDetectionEnabled
            config.tripodHeadWasMoving = proto.tripodHeadWasMoving
            if proto.numberOfFramesToProcessConcurrently > 0 {
                config.numberOfFramesToProcessConcurrently = Int(proto.numberOfFramesToProcessConcurrently)
            }
            await session.configManager.update(config)
            try await transport.respond(id: id, payload: Mapping.protoConfig(config).serializedData())
        } catch {
            await transport.sendError(id: id, message: "\(error)")
        }
    }
}
