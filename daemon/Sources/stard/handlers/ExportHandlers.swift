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
            let concurrency = config.frameConcurrency

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
    // FFmpegCodec.availableVideoCodecs / codec.availableEncoders / encoder.usablePixelFormats /
    // encoder.supportedMuxers relationships: only what the bundled ffmpeg has and this machine
    // can run (a GPU encoder appears only on a machine with the GPU), and only pixel formats
    // a folder of images can be converted to.
    static func getVideoCapabilities(id: UInt64, payload: Data, transport: StdioTransport) async {
        do {
            var caps = Star_V1_VideoCapabilities()
            caps.frameRates = FrameRate.allCases
                .filter { if case .custom = $0 { false } else { true } }
                .map { $0.rawValue }

            for codec in FFmpegCodec.availableVideoCodecs {
                var cc = Star_V1_CodecCaps()
                cc.codec = codec.rawValue
                for enc in codec.availableEncoders {
                    var ec = Star_V1_EncoderCaps()
                    ec.encoder       = enc.rawValue
                    ec.pixelFormats  = enc.usablePixelFormats.map { $0.rawValue }
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

    // The encode settings an export uses, and whether it puts the video's own sound back.
    //
    // The settings come from (priority order):
    //   1. the request, if it names a codec (the desktop's Render Video dialog always does)
    //   2. the VideoInfo the session was opened with (decoded from the source video)
    //   3. the config's video fields (may be defaults)
    //
    // Whether there is sound to put back is not one of them.  A request's settings say how to
    // encode; they cannot say what the video that was imported had, so that comes from the
    // session whichever settings are used.  This used to read `false` for every request that
    // carried settings, which was every request the desktop client sent, and each export of a
    // video with sound came out silent.  A session resumed from its config has no VideoInfo of
    // its own, but the config recorded the sound when the video was first opened.
    static func videoInfo(for request: Star_V1_VideoEncodeSettings,
                          opened: VideoInfo?,
                          config: Config) -> VideoInfo
    {
        let hasAudio = opened?.hasAudio ?? config.hasAudio
        if let fromRequest = Mapping.videoInfo(from: request, hasAudio: hasAudio) {
            return fromRequest
        }
        return opened ?? Mapping.videoInfoFromConfig(config)
    }

    // Where an export writes its video: the request's path, or if it left that empty (the
    // desktop's dialog does) the one the protocol promises, `<basename>.<muxer>`.  That is
    // beside the folder of rendered frames, which is where the Mac app's dialog puts it too.
    static func outputVideoPath(requested: String, config: Config, muxer: FFmpegMuxer) -> String {
        guard requested.isEmpty else { return requested }
        return "\(config.outputPath)/\(config.basename).\(muxer.defaultFileExtension ?? muxer.rawValue)"
    }

    // Assemble processed output TIFFs back into a video using ffmpeg.
    // Streams ProgressEvent items (io_progress, sequence_state) while encoding.
    static func video(id: UInt64, payload: Data, transport: StdioTransport, sessions: SessionManager) async {
        do {
            let req = try Star_V1_ExportVideoRequest(serializedBytes: payload)
            guard let session = await sessions.get(id: req.sessionID) else {
                await transport.sendError(id: id, message: "session not found", code: 404); return
            }

            let config = await session.configManager.config()
            let opened = await session.videoInfo
            let vi = videoInfo(for: req.settings, opened: opened, config: config)

            // The file to write: the request's, or the protocol's default when it names none.
            let videoPath = outputVideoPath(requested: req.outputVideoPath, config: config, muxer: vi.muxer)

            let outputPath = config.outputPath
            let totalFrames = await session.frameCount

            // A render leaves its frames in the config's output sequence folder, which is a
            // folder of its own inside outputPath, named after the sequence.
            let framesPath = config.outputSequenceDirname

            // Derive the decoded-frames directory from the image sequence filenames
            // so we can find the sound file decodeVideo kept beside them, if it did.
            let filenames    = await session.imageSequence.filenames
            let decodedDir   = (filenames.first as NSString?)?.deletingLastPathComponent ?? outputPath

            // What the output container will take of that sound: as it is, AAC, Opus, or nothing.
            // The muxer is chosen from the output file's extension, as the ffmpeg run below does.
            let audio = vi.hasAudio  // StarCore.VideoInfo.hasAudio
              ? AudioSidecar.plan(in: decodedDir,
                                  formatArguments: [],
                                  outputExtension: URL(fileURLWithPath: videoPath).pathExtension)
              : AudioPlan.none("the video has none")

            // Determine the encoder name: prefer explicit encoder, then codec's rawValue.
            let encoderName  = vi.encoder?.rawValue ?? vi.codec.rawValue

            var ffmpegArgs: [String] = [
                "-framerate", vi.frameRate.rawString,
                "-start_number", "1",
                "-i", "\(framesPath)/image_%04d.tiff",
            ]
            ffmpegArgs += audio.inputArguments
            ffmpegArgs += [
                "-c:v", encoderName,
                "-pix_fmt", vi.pixelFormat.rawValue,
            ]
            // for the GPU encoders whose own default quality is poor (see FFmpegHardware.swift)
            ffmpegArgs += vi.encoder?.defaultQualityArguments ?? []
            ffmpegArgs += audio.codecArguments
            ffmpegArgs += ["-y", videoPath]

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
