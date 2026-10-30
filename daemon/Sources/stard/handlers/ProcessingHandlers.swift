import Foundation
import StarCore
import StarDaemonMessages
import SwiftProtobuf
import logging

enum ProcessingHandlers {
    /// The frame range a `StartProcessingRequest` asks for.  A negative `end` (the clients send
    /// -1) means "to the end of the sequence", which is `nil`.  0 is the first frame: a request
    /// for just frame 0 is start=end=0, and must not turn into the whole sequence.
    static func frameRange(start: Int32, end: Int32) -> (start: Int, end: Int?) {
        (start > 0 ? Int(start) : 0, end >= 0 ? Int(end) : nil)
    }

    /// What `Processing.Start` does.  A run already going is superseded by this one, as the macOS gui's `processFrames` does: the old run
    /// is stopped (not announced as cancelled: to a client watching it is replaced, not ended) and this range is run instead.  It used to
    /// return success and do nothing, so "Process from here" during a run was a button that did nothing (L8).  `force` clears the frames
    /// first and has always superseded.
    static func begin(_ session: Session, startIndex: Int, endIndex: Int?, force: Bool) async {
        if force {
            await session.forceReprocess(startIndex: startIndex, endIndex: endIndex)
        } else {
            await session.restartProcessing(startIndex: startIndex, endIndex: endIndex)
        }
    }

    static func start(id: UInt64, payload: Data, transport: StdioTransport, sessions: SessionManager) async {
        do {
            let req = try Star_V1_StartProcessingRequest(serializedBytes: payload)
            guard let session = await sessions.get(id: req.sessionID) else {
                await transport.sendError(id: id, message: "session not found", code: 404)
                return
            }
            let (startIdx, endIdx) = frameRange(start: req.startIndex, end: req.endIndex)
            await begin(session, startIndex: startIdx, endIndex: endIdx, force: req.force)
            try await transport.respond(id: id, payload: Star_V1_StartProcessingResponse().serializedData())
        } catch {
            await transport.sendError(id: id, message: "\(error)")
        }
    }

    /// `Processing.Restart`: stop the run in progress, wait for it to stop, and start over the range asked for (the settings changed over a run
    /// that was going).  Answered once the new run has been started.
    static func restart(id: UInt64, payload: Data, transport: StdioTransport, sessions: SessionManager) async {
        do {
            let req = try Star_V1_StartProcessingRequest(serializedBytes: payload)
            guard let session = await sessions.get(id: req.sessionID) else {
                await transport.sendError(id: id, message: "session not found", code: 404)
                return
            }
            let (startIdx, endIdx) = frameRange(start: req.startIndex, end: req.endIndex)
            await session.restartProcessing(startIndex: startIdx, endIndex: endIdx)
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

            // Subscribe this stream, then tell it where every frame already is: the events from
            // building the frames were sent before there was anybody to hear them.
            let (stream, cont) = AsyncStream<Star_V1_ProgressEvent>.makeStream()
            let token = await session.addProgressSubscriber(cont)
            await session.seedFrameStates(to: cont)

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
            await session.removeProgressSubscriber(token)
        } catch {
            await transport.sendError(id: id, message: "\(error)")
        }
    }

    // Granular reprocess of selected frames (grid context menu). Progress streams over StreamProgress.
    static func reprocessFrames(id: UInt64, payload: Data, transport: StdioTransport, sessions: SessionManager) async {
        do {
            let req = try Star_V1_ReprocessFramesRequest(serializedBytes: payload)
            guard let session = await sessions.get(id: req.sessionID) else {
                await transport.sendError(id: id, message: "session not found", code: 404); return
            }
            let indices = req.frameIndices.map { Int($0) }
            await session.reprocessFrames(indices: indices, type: Mapping.reprocessingType(req.type))
            try await transport.respond(id: id, payload: Star_V1_ReprocessFramesResponse().serializedData())
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
