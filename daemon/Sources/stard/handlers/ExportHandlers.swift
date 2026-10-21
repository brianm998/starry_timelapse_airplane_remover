import Foundation
import StarCore
import StarDaemonMessages
import SwiftProtobuf
import logging

enum ExportHandlers {
    // Write the finished image of every frame that does not have one that is up to date, the way "Render
    // this frame" does for one: the frame's outliers are loaded first (a resumed session has them
    // purged to disk, and a frame finished without them has nothing removed), and a frame that is
    // already complete, with no edit waiting to be saved, is left alone.
    // Streams ProgressEvent items while writing: frame_saving_state from the session's callback bridges, as
    // each frame is written, and io_progress (frames done of all frames) as each one ends.
    // This stream is a subscriber of its own for as long as the render runs, so the existing
    // callback bridges emit events to it as each frame writes its output, alongside the client's
    // long-lived Processing.StreamProgress, which hears them too.  The completion event goes to
    // this stream only: it is not the end of a processing run.
    static func renderSequence(id: UInt64, payload: Data, transport: StdioTransport, sessions: SessionManager) async {
        do {
            let req = try Star_V1_SessionRef(serializedBytes: payload)
            guard let session = await sessions.get(id: req.sessionID) else {
                await transport.sendError(id: id, message: "session not found", code: 404); return
            }

            // Subscribe this stream so that frameSavingStateChangeCallback events reach the client.
            let (stream, cont) = AsyncStream<Star_V1_ProgressEvent>.makeStream()
            let token = await session.addProgressSubscriber(cont)

            let frames = await session.frames
            let config = await session.configManager.config()
            let concurrency = config.frameConcurrency
            let total = Int32(frames.count)

            // Finish all frames concurrently, respecting the configured limit.
            let finishTask = Task {
                var done: Int32 = 0
                let reportProgress = { (done: Int32) in
                    var io = Star_V1_IoProgress()
                    io.current = done
                    io.total = total
                    var prog = Star_V1_ProgressEvent()
                    prog.kind = .ioProgress(io)
                    cont.yield(prog)
                }
                await withTaskGroup(of: Void.self) { group in
                    var inFlight = 0
                    for frame in frames {
                        if inFlight >= concurrency {
                            await group.next()
                            inFlight -= 1
                            done += 1
                            reportProgress(done)
                        }
                        group.addTask {
                            if await frame.processingState() == .complete, await frame.savingState() == .notSaving {
                                return
                            }
                            await ensureOutliersLoaded(frame)
                            if await !session.renderNow(frame) {
                                Log.e("Export.RenderSequence: frame \(frame.frameIndex) could not be rendered")
                            }
                        }
                        inFlight += 1
                    }
                    while await group.next() != nil {
                        done += 1
                        reportProgress(done)
                    }
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
            // Past the "done" sentinel this does nothing.  Otherwise the stream was ended from
            // under it -- the session closed -- and the render must not carry on without it.
            finishTask.cancel()

            await session.removeProgressSubscriber(token)
            await transport.sendStreamEnd(id: id)
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
            try await transport.respond(id: id, payload: videoCapabilities().serializedData())
        } catch {
            await transport.sendError(id: id, message: "\(error)")
        }
    }

    /// The capability graph with what each entry is, for the dialog's descriptions (macOS `RenderVideoSheetView`): why a frame rate, what a codec
    /// is, what an encoder is, how many components and bits a pixel format has, and what container a muxer is and what its files are called.
    static func videoCapabilities() -> Star_V1_VideoCapabilities {
        var caps = Star_V1_VideoCapabilities()
        let standard = FrameRate.allCases.filter { if case .custom = $0 { false } else { true } }
        caps.frameRates = standard.map { $0.rawValue }
        for rate in standard {
            var fc = Star_V1_FrameRateCaps()
            fc.value = rate.rawValue
            fc.description_p = rate.description
            caps.frameRateCaps.append(fc)
        }
        // Custom is a choice of its own: any rate from a field, which the daemon accepts as long as it is positive.
        var custom = Star_V1_FrameRateCaps()
        custom.custom = true
        custom.value = 24
        custom.description_p = FrameRate.custom(24).description
        caps.frameRateCaps.append(custom)

        for codec in FFmpegCodec.availableVideoCodecs {
            var cc = Star_V1_CodecCaps()
            cc.codec = codec.rawValue
            cc.description_p = codec.description
            for enc in codec.availableEncoders {
                var ec = Star_V1_EncoderCaps()
                ec.encoder       = enc.rawValue
                ec.description_p = enc.description
                let formats = VideoExport.prioritized(
                    enc.usablePixelFormats.map { $0.rawValue }, preferred: VideoExport.preferredPixelFormats)
                let muxers = VideoExport.prioritized(
                    enc.supportedMuxers.map { $0.rawValue }, preferred: VideoExport.preferredMuxers)
                ec.pixelFormats = formats
                ec.muxers       = muxers
                for name in formats {
                    guard let format = FFmpegPixelFormat(rawValue: name) else { continue }
                    var pc = Star_V1_PixelFormatCaps()
                    pc.name = name
                    pc.components = Int32(format.numberOfComponents)
                    pc.bitsPerPixel = Int32(format.bitsPerPixel)
                    pc.bitDepths = format.bitDepths
                    ec.pixelFormatCaps.append(pc)
                }
                for name in muxers {
                    guard let muxer = FFmpegMuxer(rawValue: name) else { continue }
                    var mc = Star_V1_MuxerCaps()
                    mc.name = name
                    mc.description_p = muxer.description
                    mc.fileExtension = muxer.defaultFileExtension ?? muxer.rawValue
                    ec.muxerCaps.append(mc)
                }
                cc.encoders.append(ec)
            }
            caps.codecs.append(cc)
        }
        return caps
    }

    /// `Export.GetDefaultVideoPath`: where a video would be written for this container, before anything is rendered.
    static func getDefaultVideoPath(id: UInt64, payload: Data, transport: StdioTransport, sessions: SessionManager) async {
        do {
            let req = try Star_V1_GetDefaultVideoPathRequest(serializedBytes: payload)
            guard let session = await sessions.get(id: req.sessionID) else {
                await transport.sendError(id: id, message: "session not found", code: 404); return
            }
            let config = await session.configManager.config()
            let muxer = FFmpegMuxer(rawValue: req.muxer) ?? config.muxer
            var resp = Star_V1_GetDefaultVideoPathResponse()
            resp.outputVideoPath = URL(fileURLWithPath: VideoExport.defaultOutputPath(config: config, muxer: muxer)).path
            try await transport.respond(id: id, payload: resp.serializedData())
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
        // the resolution is a choice of this render, so it is kept when the rest is not the request's
        var base = opened ?? Mapping.videoInfoFromConfig(config)
        base = VideoInfo(frameRate: base.frameRate, codec: base.codec, encoder: base.encoder,
                         pixelFormat: base.pixelFormat, muxer: base.muxer, hasAudio: base.hasAudio,
                         resolution: OutputResolution(height: Int(request.outputHeight)))
        return base
    }

    // Where an export writes its video: the request's path, or if it left that empty (the
    // desktop's dialog does) the one the protocol promises, `<basename>.<container's extension>`.
    // That is beside the folder of rendered frames, which is where the Mac app's dialog puts it too.
    static func outputVideoPath(requested: String, config: Config, muxer: FFmpegMuxer) -> String {
        guard requested.isEmpty else { return requested }
        return VideoExport.defaultOutputPath(config: config, muxer: muxer)
    }

    // The event that tells a client where an export's video went.  The client may not have named
    // the file (the desktop's dialog never does), so the daemon says, and as an absolute path: a
    // relative one is relative to the daemon's working directory, which nobody else can see.
    static func videoExportedEvent(path: String) -> Star_V1_ProgressEvent {
        var exported = Star_V1_VideoExportedEvent()
        exported.outputVideoPath = URL(fileURLWithPath: path).path
        var event = Star_V1_ProgressEvent()
        event.kind = .videoExported(exported)
        return event
    }

    // Assemble the processed output frames back into a video using ffmpeg.
    // Streams ProgressEvent items (io_progress, sequence_state) while encoding, and when the video
    // is written, a video_exported with where it went.
    //
    // The frames are the ones processing has already written to the output sequence directory
    // (MergeOp finishes each frame as the graph runs), so Export.RenderSequence is not needed
    // first; it only re-renders frames after their outliers were edited.  See VideoExport for
    // how those files are found and handed to ffmpeg.
    static func video(id: UInt64, payload: Data, transport: StdioTransport, sessions: SessionManager) async {
        do {
            let req = try Star_V1_ExportVideoRequest(serializedBytes: payload)
            guard let session = await sessions.get(id: req.sessionID) else {
                await transport.sendError(id: id, message: "session not found", code: 404); return
            }

            let config = await session.configManager.config()
            let opened = await session.videoInfo
            let vi = videoInfo(for: req.settings, opened: opened, config: config)
            guard vi.frameRate.rawValue > 0 else {
                await transport.sendError(id: id, message: "invalid frame rate \(vi.frameRate.rawValue)")
                return
            }

            // The file to write: the request's, or the protocol's default when it names none.
            let videoPath = outputVideoPath(requested: req.outputVideoPath, config: config, muxer: vi.muxer)

            let outputPath = config.outputPath

            // The frames processing wrote, in frame order.
            let filenames = await session.imageSequence.filenames
            let frameDir  = config.outputSequenceDirname
            let found     = VideoExport.finalFrames(outputDir: frameDir, sourceFilenames: filenames)
            guard !found.files.isEmpty else {
                await transport.sendError(
                    id: id,
                    message: "nothing to export: no processed frames found in \(frameDir); process the sequence first")
                return
            }
            if !found.missing.isEmpty {
                // A partly processed sequence still renders what it has, as the macOS gui's
                // render does; say so rather than leave a video that silently skips frames.
                let sample = found.missing.prefix(5).joined(separator: ", ")
                Log.w("Export.Video: \(found.missing.count) of \(filenames.count) frames have no output in \(frameDir) and are left out (\(sample)\(found.missing.count > 5 ? ", ..." : ""))")
            }
            let totalFrames = found.files.count

            // Derive the decoded-frames directory from the image sequence filenames
            // so we can find the sound file decodeVideo kept beside them, if it did.
            let decodedDir = (filenames.first as NSString?)?.deletingLastPathComponent ?? outputPath

            // What the output container will take of that sound: as it is, AAC, Opus, or nothing.
            // The container is the one the arguments below name with `-f`.
            let audio = vi.hasAudio  // StarCore.VideoInfo.hasAudio
              ? AudioSidecar.plan(in: decodedDir,
                                  formatArguments: ["-f", vi.muxer.rawValue],
                                  outputExtension: "")
              : AudioPlan.none("the video has none")

            // The list is a file for as long as ffmpeg takes to read it.
            let listPath = "\(await session.scratchSessionDir)/export-\(UUID().uuidString).ffconcat"
            try VideoExport.concatList(files: found.files, frameRate: vi.frameRate)
                .write(toFile: listPath, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(atPath: listPath) }

            let ffmpegArgs = VideoExport.arguments(
                listPath: listPath,
                audio: audio,
                videoInfo: vi,
                outputVideoPath: videoPath
            )

            let (stream, cont) = AsyncStream<Star_V1_ProgressEvent>.makeStream()

            let encodeTask = Task {
                defer {
                    var ev = Star_V1_SequenceStateEvent(); ev.state = "done"
                    var prog = Star_V1_ProgressEvent(); prog.kind = .sequenceState(ev)
                    cont.yield(prog); cont.finish()
                }
                try await runCancellableFFmpegWithProgress(
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

            // The client cancelling the request cancels this task; that has to stop ffmpeg, not just stop
            // listening to it, or the video keeps being written for a render the user gave up on.
            await withTaskCancellationHandler {
                for await event in stream {
                    if let data = try? event.serializedData() {
                        await transport.sendStreamItem(id: id, payload: data)
                    }
                    if case .sequenceState(_) = event.kind { break }
                }
            } onCancel: {
                encodeTask.cancel()
            }

            switch await encodeTask.result {
            case .failure(let err) where err is CancellationError:
                // A cancelled encode leaves a partial file at the path the user chose; do not leave it there.
                try? FileManager.default.removeItem(atPath: videoPath)
                Log.i("Export.Video: cancelled, removed the partial \(videoPath)")
                await transport.sendError(id: id, message: "cancelled", code: 499)
                return
            case .failure(let err):
                // Surface any ffmpeg error to the client.
                await transport.sendError(id: id, message: "\(err)")
                return
            case .success:
                break
            }

            // The video is written; say where.
            if let data = try? videoExportedEvent(path: videoPath).serializedData() {
                await transport.sendStreamItem(id: id, payload: data)
            }

            await transport.sendStreamEnd(id: id)
        } catch {
            await transport.sendError(id: id, message: "\(error)")
        }
    }
}
