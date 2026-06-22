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

    // Return the codec→encoder→{pixel_formats, muxers} capability graph used to
    // populate the Render Video dialog's cascading pickers.  Mirrors StarCore's
    // FFmpegCodec.availableVideoCodecs / codec.encoders / encoder.pixelFormats /
    // encoder.supportedMuxers relationships.
    static func getVideoCapabilities(id: UInt64, payload: Data, transport: StdioTransport) async {
        do {
            var caps = Star_V1_VideoCapabilities()
            caps.frameRates = FrameRate.allCases
                .filter { if case .custom = $0 { false } else { true } }
                .map { $0.rawValue }

            for codec in FFmpegCodec.availableVideoCodecs {
                var cc = Star_V1_CodecCaps()
                cc.codec = codec.rawValue
                for enc in codec.encoders {
                    var ec = Star_V1_EncoderCaps()
                    ec.encoder       = enc.rawValue
                    ec.pixelFormats  = enc.pixelFormats.map { $0.rawValue }
                    ec.muxers        = enc.supportedMuxers.map { $0.rawValue }
                    cc.encoders.append(ec)
                }
                caps.codecs.append(cc)
            }
            try await transport.respond(id: id, payload: caps.serializedData())
        } catch {
            await transport.sendError(id: id, message: "\(error)")
        }
    }

    // Assemble processed output TIFFs back into a video using ffmpeg.
    // Streams ProgressEvent items (io_progress, sequence_state) while encoding.
    static func video(id: UInt64, payload: Data, transport: StdioTransport, sessions: SessionManager) async {
        do {
            let req = try Star_V1_ExportVideoRequest(serializedBytes: payload)
            guard let session = await sessions.get(id: req.sessionID) else {
                await transport.sendError(id: id, message: "session not found", code: 404); return
            }

            // Resolve encode settings (priority order):
            //   1. Explicit settings in the request (codec field not empty)
            //   2. VideoInfo stored on the session (decoded from the source video)
            //   3. Config's video fields (may be defaults)
            let config = await session.configManager.config()
            let vi: VideoInfo
            if let fromReq = Mapping.videoInfo(from: req.settings, hasAudio: false) {
                vi = fromReq
            } else if let stored = await session.videoInfo {
                vi = stored
            } else {
                vi = Mapping.videoInfoFromConfig(config)
            }

            let outputPath = config.outputPath
            let totalFrames = await session.frameCount

            // Derive the decoded-frames directory from the image sequence filenames
            // so we can find audio.aac if it exists.
            let filenames    = await session.imageSequence.filenames
            let decodedDir   = (filenames.first as NSString?)?.deletingLastPathComponent ?? outputPath
            let audioPath    = "\(decodedDir)/audio.aac"
            let hasAudio     = vi.hasAudio && FileManager.default.fileExists(atPath: audioPath)  // StarCore.VideoInfo.hasAudio

            // Determine the encoder name: prefer explicit encoder, then codec's rawValue.
            let encoderName  = vi.encoder?.rawValue ?? vi.codec.rawValue

            var ffmpegArgs: [String] = [
                "-framerate", vi.frameRate.rawString,
                "-start_number", "1",
                "-i", "\(outputPath)/image_%04d.tiff",
            ]
            if hasAudio { ffmpegArgs += ["-i", audioPath] }
            ffmpegArgs += [
                "-c:v", encoderName,
                "-pix_fmt", vi.pixelFormat.rawValue,
            ]
            if hasAudio { ffmpegArgs += ["-c:a", "copy"] }
            ffmpegArgs += ["-y", req.outputVideoPath]

            let (stream, cont) = AsyncStream<Star_V1_ProgressEvent>.makeStream()

            let encodeTask = Task {
                defer {
                    var ev = Star_V1_SequenceStateEvent(); ev.state = "done"
                    var prog = Star_V1_ProgressEvent(); prog.kind = .sequenceState(ev)
                    cont.yield(prog); cont.finish()
                }
                try runFFmpegWithProgress(
                    arguments: ffmpegArgs,
                    totalFrames: totalFrames,
                    outputFolder: outputPath
                ) { current, total, dir in
                    var io = Star_V1_IoProgress()
                    io.current   = Int32(current)
                    io.total     = Int32(total)
                    io.outputDir = dir
                    var prog = Star_V1_ProgressEvent()
                    prog.kind = .ioProgress(io)
                    cont.yield(prog)
                }
            }

            do {
                for await event in stream {
                    try Task.checkCancellation()
                    if let data = try? event.serializedData() {
                        await transport.sendStreamItem(id: id, payload: data)
                    }
                    if case .sequenceState(_) = event.kind { break }
                }
            } catch is CancellationError {
                encodeTask.cancel()
            }

            // Surface any ffmpeg error to the client.
            if case .failure(let err) = await encodeTask.result {
                await transport.sendError(id: id, message: "\(err)")
                return
            }

            await transport.sendStreamEnd(id: id)
        } catch {
            await transport.sendError(id: id, message: "\(error)")
        }
    }
}
