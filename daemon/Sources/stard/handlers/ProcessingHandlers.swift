import Foundation
import StarCore
import StarDaemonMessages
import SwiftProtobuf
import logging

enum ProcessingHandlers {
    static func start(id: UInt64, payload: Data, transport: StdioTransport, sessions: SessionManager) async {
        do {
            let req = try Star_V1_StartProcessingRequest(serializedBytes: payload)
            guard let session = await sessions.get(id: req.sessionID) else {
                await transport.sendError(id: id, message: "session not found", code: 404)
                return
            }
            let startIdx = req.startIndex > 0 ? Int(req.startIndex) : 0
            let endIdx: Int? = req.endIndex > 0 ? Int(req.endIndex) : nil
            await session.startProcessing(startIndex: startIdx, endIndex: endIdx)
            try await transport.respond(id: id, payload: Star_V1_StartProcessingResponse().serializedData())
        } catch {
            await transport.sendError(id: id, message: "\(error)")
        }
    }

    // Processing.StreamProgress: stays open and yields ProgressEvent items.
    static func streamProgress(id: UInt64, payload: Data, transport: StdioTransport, sessions: SessionManager) async {
        do {
            let req = try Star_V1_SessionRef(serializedBytes: payload)
            guard let session = await sessions.get(id: req.sessionID) else {
                await transport.sendError(id: id, message: "session not found", code: 404)
                return
            }

            // Wire up the session's progress continuation to this stream.
            let (stream, cont) = AsyncStream<Star_V1_ProgressEvent>.makeStream()
            await session.setProgressContinuation(cont)

            // Stream items to the client until the session finishes or this task is cancelled.
            do {
                for await event in stream {
                    try Task.checkCancellation()
                    if let data = try? event.serializedData() {
                        await transport.sendStreamItem(id: id, payload: data)
                    }
                }
            } catch is CancellationError {
                // task was cancelled via CANCEL envelope
            }
            await transport.sendStreamEnd(id: id)
            await session.setProgressContinuation(nil)
        } catch {
            await transport.sendError(id: id, message: "\(error)")
        }
    }

    static func cancel(id: UInt64, payload: Data, transport: StdioTransport, sessions: SessionManager) async {
        do {
            let req = try Star_V1_SessionRef(serializedBytes: payload)
            if let session = await sessions.get(id: req.sessionID) {
                await session.cancelProcessing()
            }
            try await transport.respond(id: id, payload: Star_V1_CancelResponse().serializedData())
        } catch {
            await transport.sendError(id: id, message: "\(error)")
        }
    }
}
