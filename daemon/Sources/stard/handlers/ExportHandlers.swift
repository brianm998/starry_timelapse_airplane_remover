import Foundation
import StarCore
import StarDaemonMessages
import SwiftProtobuf
import logging

enum ExportHandlers {
    // Render all output frames by calling finish() on each frame.
    // Streams ProgressEvent items (frame_saving_state, sequence_state) while writing.
    // The session's progressContinuation is wired up so the existing callback bridges
    // automatically emit events as each frame writes its output.
    static func renderSequence(id: UInt64, payload: Data, transport: StdioTransport, sessions: SessionManager) async {
        do {
            let req = try Star_V1_SessionRef(serializedBytes: payload)
            guard let session = await sessions.get(id: req.sessionID) else {
                await transport.sendError(id: id, message: "session not found", code: 404); return
            }

            // Wire the session's progress continuation to this stream so that
            // frameSavingStateChangeCallback events reach the client.
            let (stream, cont) = AsyncStream<Star_V1_ProgressEvent>.makeStream()
            await session.setProgressContinuation(cont)

            let frames = await session.frames
            let config = await session.configManager.config()
            let concurrency = max(1, config.numberOfFramesToProcessConcurrently)

            // Finish all frames concurrently, respecting the configured limit.
            let finishTask = Task {
                await withTaskGroup(of: Void.self) { group in
                    var inFlight = 0
                    for frame in frames {
                        if inFlight >= concurrency {
                            await group.next()
                            inFlight -= 1
                        }
                        group.addTask {
                            do {
                                try await frame.finish()
                            } catch {
                                Log.e("Export.RenderSequence: frame \(frame.frameIndex) finish error: \(error)")
                            }
                        }
                        inFlight += 1
                    }
                    await group.waitForAll()
                }
                // Signal sequence completion so the stream can end.
                var ev = Star_V1_SequenceStateEvent()
                ev.state = "done"
                var prog = Star_V1_ProgressEvent()
                prog.kind = .sequenceState(ev)
                cont.yield(prog)
                cont.finish()
            }

            // Forward events to the client until the finish task completes.
            do {
                for await event in stream {
                    try Task.checkCancellation()
                    if let data = try? event.serializedData() {
                        await transport.sendStreamItem(id: id, payload: data)
                    }
                    // Stop after the sequence_state "done" sentinel.
                    if case .sequenceState(_) = event.kind { break }
                }
            } catch is CancellationError {
                finishTask.cancel()
            }

            await transport.sendStreamEnd(id: id)
            await session.setProgressContinuation(nil)
        } catch {
            await transport.sendError(id: id, message: "\(error)")
        }
    }

    static func video(id: UInt64, payload: Data, transport: StdioTransport, sessions: SessionManager) async {
        // Phase 4: Export frames to video via VideoConvert / ffmpeg.
        await transport.sendError(id: id, message: "Export.Video not yet implemented (Phase 4)", code: 501)
    }
}
