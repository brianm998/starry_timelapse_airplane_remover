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
            let concurrency = max(1, config.numberOfFramesToProcessConcurrently)
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
                    ec.pixelFormats  = VideoExport.prioritized(
                        enc.pixelFormats.map { $0.rawValue }, preferred: VideoExport.preferredPixelFormats)
                    ec.muxers        = VideoExport.prioritized(
                        enc.supportedMuxers.map { $0.rawValue }, preferred: VideoExport.preferredMuxers)
                    cc.encoders.append(ec)
                }
                caps.codecs.append(cc)
            }
            try await transport.respond(id: id, payload: caps.serializedData())
        } catch {
            await transport.sendError(id: id, message: "\(error)")
        }
    }

    // Assemble the processed output frames back into a video using ffmpeg.
    // Streams ProgressEvent items (io_progress, sequence_state) while encoding.
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

            // Resolve encode settings (priority order):
            //   1. Explicit settings in the request (codec field not empty)
            //   2. VideoInfo stored on the session (decoded from the source video)
            //   3. Config's video fields (may be defaults)
            // Whether there is an audio track is a fact about the source, not an encode
            // setting, so it comes from the session either way.
            let config = await session.configManager.config()
            let sourceHasAudio = await session.videoInfo?.hasAudio ?? config.hasAudio
            let vi: VideoInfo
            if let fromReq = Mapping.videoInfo(from: req.settings, hasAudio: sourceHasAudio) {
                vi = fromReq
            } else if let stored = await session.videoInfo {
                vi = stored
            } else {
                vi = Mapping.videoInfoFromConfig(config)
            }
            guard vi.frameRate.rawValue > 0 else {
                await transport.sendError(id: id, message: "invalid frame rate \(vi.frameRate.rawValue)")
                return
            }

            let outputPath = config.outputPath

            // The frames processing wrote, in frame order.
            let filenames = await session.imageSequence.filenames
            let frameDir  = config.outputSequenceDirname
            let found     = VideoExport.finalFrames(outputDir: frameDir, sourceFilenames: filenames)
            guard !found.files.isEmpty else {
                await transport.sendError(
                    id: id,
                    message: "no processed frames found in \(frameDir); process the sequence first")
                return
            }
            if !found.missing.isEmpty {
                // A partly processed sequence still renders what it has, as the macOS gui's
                // render does; say so rather than leave a video that silently skips frames.
                let sample = found.missing.prefix(5).joined(separator: ", ")
                Log.w("Export.Video: \(found.missing.count) of \(filenames.count) frames have no output in \(frameDir) and are left out (\(sample)\(found.missing.count > 5 ? ", ..." : ""))")
            }
            let totalFrames = found.files.count

            // The decoded-frames directory of a video import is also where its audio.aac is.
            let decodedDir = (filenames.first as NSString?)?.deletingLastPathComponent ?? outputPath
            let audioFile  = "\(decodedDir)/audio.aac"
            let audioPath  = vi.hasAudio && FileManager.default.fileExists(atPath: audioFile) ? audioFile : nil

            let outputVideoPath = req.outputVideoPath.isEmpty
                ? VideoExport.defaultOutputPath(config: config, muxer: vi.muxer)
                : req.outputVideoPath

            let listPath = "\(await session.scratchSessionDir)/export-\(UUID().uuidString).ffconcat"
            try VideoExport.concatList(files: found.files, frameRate: vi.frameRate)
                .write(toFile: listPath, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(atPath: listPath) }

            let ffmpegArgs = VideoExport.arguments(
                listPath: listPath,
                audioPath: audioPath,
                videoInfo: vi,
                outputVideoPath: outputVideoPath
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
                try? FileManager.default.removeItem(atPath: outputVideoPath)
                Log.i("Export.Video: cancelled, removed the partial \(outputVideoPath)")
                await transport.sendError(id: id, message: "cancelled", code: 499)
                return
            case .failure(let err):
                // Surface any ffmpeg error to the client.
                await transport.sendError(id: id, message: "\(err)")
                return
            case .success:
                break
            }

            await transport.sendStreamEnd(id: id)
        } catch {
            await transport.sendError(id: id, message: "\(error)")
        }
    }
}
