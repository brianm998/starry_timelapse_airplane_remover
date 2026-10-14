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
            await session.didOpen()
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
            await session.didOpen()
            let config = await session.configManager.config()
            let imageInfo = await session.imageInfo
            let frameCount = await session.frameCount
            let info = Mapping.sessionInfo(session: session, config: config, imageInfo: imageInfo, frameCount: frameCount)
            try await transport.respond(id: id, payload: info.serializedData())
        } catch {
            await transport.sendError(id: id, message: "\(error)")
        }
    }

    /// `Session.OpenVideo`: decodes the video to frames, then opens them; streams how it is going, then the session.
    static func openVideo(id: UInt64, payload: Data, transport: StdioTransport, sessions: SessionManager) async {
        do {
            let req = try Star_V1_OpenVideoRequest(serializedBytes: payload)
            let sessionID = await sessions.newSessionID()
            let scratchDir = await sessions.scratchDir(for: sessionID)
            await streamOpen(id: id, transport: transport, sessions: sessions, scratchDir: scratchDir) { report in
                try await Session.openVideo(sessionID: sessionID, scratchSessionDir: scratchDir, videoPath: req.videoPath,
                                            protoConfig: req.initialConfig, report: report)
            }
        } catch {
            await transport.sendError(id: id, message: "\(error)")
        }
    }

    /// `Session.OpenSequenceStream`: as `OpenSequence`, but streams how the frames are coming (`FramesLoaded`) and can be cancelled.
    static func openSequenceStream(id: UInt64, payload: Data, transport: StdioTransport, sessions: SessionManager) async {
        do {
            let req = try Star_V1_OpenSequenceRequest(serializedBytes: payload)
            let sessionID = await sessions.newSessionID()
            let scratchDir = await sessions.scratchDir(for: sessionID)
            await streamOpen(id: id, transport: transport, sessions: sessions, scratchDir: scratchDir) { report in
                try await Session.openSequence(sessionID: sessionID, scratchSessionDir: scratchDir, sequenceDir: req.sequenceDir,
                                               protoConfig: req.initialConfig, report: report)
            }
        } catch {
            await transport.sendError(id: id, message: "\(error)")
        }
    }

    /// `Session.OpenConfigStream`: as `OpenConfig`, but streams how the frames are coming and can be cancelled.
    static func openConfigStream(id: UInt64, payload: Data, transport: StdioTransport, sessions: SessionManager) async {
        do {
            let req = try Star_V1_OpenConfigRequest(serializedBytes: payload)
            let sessionID = await sessions.newSessionID()
            let scratchDir = await sessions.scratchDir(for: sessionID)
            await streamOpen(id: id, transport: transport, sessions: sessions, scratchDir: scratchDir) { report in
                try await Session.openConfig(sessionID: sessionID, scratchSessionDir: scratchDir, configPath: req.configJsonPath, report: report)
            }
        } catch {
            await transport.sendError(id: id, message: "\(error)")
        }
    }

    /// Run an open and answer as a stream: its stage and progress events as it works, then the new session's info as the last item.
    ///
    /// Cancelling the call cancels the work (which stops ffmpeg if it was decoding, and otherwise stops between frames), and whatever session
    /// the work had already made is closed and its scratch directory removed: the client has gone, and nothing else knows about it.  The work
    /// is its own task, not a child of this one, because the events have to be forwarded from here while it runs.
    private static func streamOpen(
        id: UInt64, transport: StdioTransport, sessions: SessionManager, scratchDir: String,
        open: @escaping @Sendable (_ report: @escaping OpenReport) async throws -> Session
    ) async {
        let (stream, continuation) = AsyncStream<Star_V1_OpenProgress>.makeStream()
        let work = Task<Session, Error> {
            defer { continuation.finish() }
            return try await open { continuation.yield($0) }
        }

        let outcome: Result<Session, Error> = await withTaskCancellationHandler {
            for await item in stream {
                if let data = try? item.serializedData() {
                    await transport.sendStreamItem(id: id, payload: data)
                }
            }
            return await work.result
        } onCancel: {
            work.cancel()
        }

        if Task.isCancelled {
            if case .success(let session) = outcome { await session.close() }
            try? FileManager.default.removeItem(atPath: scratchDir)
            Log.i("stard: an open was cancelled by its client")
            return
        }

        switch outcome {
        case .failure(let error):
            await transport.sendError(id: id, message: "\(error)")
        case .success(let session):
            await sessions.add(session: session)
            await session.didOpen()
            let config     = await session.configManager.config()
            let imageInfo  = await session.imageInfo
            let frameCount = await session.frameCount
            let info = Mapping.sessionInfo(session: session, config: config, imageInfo: imageInfo,
                                           frameCount: frameCount, videoInfo: await session.videoInfo)
            var done = Star_V1_OpenProgress()
            done.kind = .done(info)
            if let data = try? done.serializedData() {
                await transport.sendStreamItem(id: id, payload: data)
            }
            await transport.sendStreamEnd(id: id)
        }
    }

    static func close(id: UInt64, payload: Data, transport: StdioTransport, sessions: SessionManager) async {
        do {
            let req = try Star_V1_CloseSessionRequest(serializedBytes: payload)
            // Stop and drain the session before it is dropped: its run must not outlive it.  An
            // unknown id is a close of something already closed, and harmless.
            if let session = await sessions.get(id: req.sessionID) {
                await session.close()
            }
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
