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
        do {
            let req = try Star_V1_OpenVideoRequest(serializedBytes: payload)
            let sessionID = await sessions.newSessionID()
            let scratchDir = await sessions.scratchDir(for: sessionID)

            // Bridge the synchronous ffmpeg progress callback to an AsyncStream.
            let (stream, cont) = AsyncStream<Star_V1_OpenProgress>.makeStream()

            // Run decodeVideo + frame-graph build in a detached task.
            // When it completes (or fails) it finishes the stream so the loop below exits.
            let sessionTask: Task<Session, Error> = Task {
                defer { cont.finish() }
                return try await Session.openVideo(
                    sessionID: sessionID,
                    scratchSessionDir: scratchDir,
                    videoPath: req.videoPath,
                    protoConfig: req.initialConfig
                ) { current, total, outputDir in
                    var io = Star_V1_IoProgress()
                    io.current   = Int32(current)
                    io.total     = Int32(total)
                    io.outputDir = outputDir
                    var prog = Star_V1_OpenProgress()
                    prog.kind = .progress(io)
                    cont.yield(prog)
                }
            }

            // Forward IoProgress items to the client while decoding + graph-build run.
            for await item in stream {
                if let data = try? item.serializedData() {
                    await transport.sendStreamItem(id: id, payload: data)
                }
            }

            let session: Session
            do {
                session = try await sessionTask.value
            } catch {
                await transport.sendError(id: id, message: "\(error)")
                return
            }

            await sessions.add(session: session)

            // Send final SessionInfo as the last stream item, then STREAM_END.
            let config     = await session.configManager.config()
            let imageInfo  = await session.imageInfo
            let frameCount = await session.frameCount
            let vi         = await session.videoInfo
            let info = Mapping.sessionInfo(session: session, config: config, imageInfo: imageInfo,
                                           frameCount: frameCount, videoInfo: vi)
            var done = Star_V1_OpenProgress()
            done.kind = .done(info)
            if let data = try? done.serializedData() {
                await transport.sendStreamItem(id: id, payload: data)
            }
            await transport.sendStreamEnd(id: id)
        } catch {
            await transport.sendError(id: id, message: "\(error)")
        }
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
