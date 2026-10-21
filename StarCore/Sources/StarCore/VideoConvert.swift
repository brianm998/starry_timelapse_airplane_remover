import Foundation
import logging

public typealias ProgressCallback =
  @Sendable
  (
    _ currentFrame: Int,
    _ totalFrames: Int,
    _ outputDir: String
  ) -> Void

public struct VideoInfo: Sendable {
    public let frameRate: FrameRate
    public let codec: FFmpegCodec
    public let encoder: FFmpegEncoder?
    public let pixelFormat: FFmpegPixelFormat
    public let muxer: FFmpegMuxer
    public let hasAudio: Bool
    /// What a render scales to; the source video's own info never sets it.
    public let resolution: OutputResolution

    public init(frameRate: FrameRate, codec: FFmpegCodec, encoder: FFmpegEncoder?,
                pixelFormat: FFmpegPixelFormat, muxer: FFmpegMuxer, hasAudio: Bool,
                resolution: OutputResolution = .original) {
        self.frameRate = frameRate
        self.codec = codec
        self.encoder = encoder
        self.pixelFormat = pixelFormat
        self.muxer = muxer
        self.hasAudio = hasAudio
        self.resolution = resolution
    }
}


/// Process a video: extract frames and audio and video information.  The audio, if it has any, is kept
/// beside the frames by `AudioSidecar`, in its own codec where that is possible.
public func decodeVideo(
    named inputPath: String,
    format: FrameDecodeFormat = .tiff16,
    progress progressCallback: @escaping ProgressCallback
) async throws -> (outputDirectory: String, videoInfo: VideoInfo) {
    let inputURL = URL(fileURLWithPath: inputPath)
    let fileName = inputURL.deletingPathExtension().lastPathComponent
    //let fileExtension = inputURL.pathExtension
    // Sanitize only the new folder's name. Sanitizing the whole path turned a
    // Windows path like C:\Users\me\Desktop\x.mp4 into the relative path
    // C__Users_me_Desktop_x, which ffmpeg then failed to write to (EIO, -5).
    let outputFolder = inputURL
      .deletingLastPathComponent()
      .appendingPathComponent(fileName.sanitized)
      .path
    let fileManager = FileManager.default

    // Whether this call is the one that makes the folder: a decode that is given up on takes back what it made, and only that.  Frames
    // left half written would make the next attempt at the same video fail (ffmpeg will not overwrite them), and a folder that was
    // there before is not this call's to remove.
    let createdOutputFolder = !fileManager.fileExists(atPath: outputFolder)
    try? fileManager.createDirectory(atPath: outputFolder, withIntermediateDirectories: true)

    let ffprobePath = ToolPaths.ffprobe
    let ffmpegPath = ToolPaths.ffmpeg
    Log.i("decoding \(inputPath) with ffmpeg at \(ffmpegPath)")

    // The frame count is only the denominator of the extraction progress, so it is read the cheapest way that works: the header,
    // then a packet count (demuxes without decoding), and only then the decode-everything count that used to run every time.
    let totalFramesTask = Task { videoFrameCount(of: inputPath, ffprobePath: ffprobePath) }
    let totalFrames = await totalFramesTask.value
    // Counting the frames can be a probe that cannot be interrupted, so this is the first place a caller that gave up on the video is noticed.
    do { try Task.checkCancellation() } catch {
        if createdOutputFolder { try? fileManager.removeItem(atPath: outputFolder) }
        throw error
    }

    // A header-derived count can be a little low, and progress past the end of the bar is worse than a bar that finishes early.
    let progress: ProgressCallback = { current, total, outputDir in
        progressCallback(current, total > 0 ? max(total, current) : total, outputDir)
    }

    // software decode unless the user opted in; see FFmpegHardware for why
    var decodeArguments = FFmpegHardware.decodeArguments()
    decodeArguments += ["-i", inputPath] + format.ffmpegOutputArguments(in: outputFolder)
    let framesArguments = decodeArguments

    // The cancellable run, so that a caller who gives up stops ffmpeg rather than leaving it to decode the rest of the video.  Not
    // cancelled, it does the same thing as `runFFmpegWithProgress`.
    let ffmpegTask = Task {
        try await runCancellableFFmpegWithProgress(
          arguments: framesArguments,
          totalFrames: totalFrames,
          outputFolder: outputFolder,
          progress: progress
        )
    }

    do {
        return try await withTaskCancellationHandler {
            let hasAudioTask = Task {
                (try? shellOut(
                   to: ffprobePath,
                   arguments: [
                     "-v", "error", "-select_streams", "a:0",
                     "-show_entries", "stream=codec_type",
                     "-of", "default=noprint_wrappers=1:nokey=1",
                     inputPath
                   ]
                 ).trimmingCharacters(in: .whitespacesAndNewlines)) == "audio"
            }

            let frameRateTask = Task {
                try shellOut(
                  to: ffprobePath,
                  arguments: [
                    "-v", "error", "-select_streams", "v:0",
                    "-show_entries", "stream=r_frame_rate",
                    "-of", "default=noprint_wrappers=1:nokey=1",
                    inputPath
                  ]
                ).trimmingCharacters(in: .whitespacesAndNewlines)        
            }

            let codecTask = Task {
                try shellOut(
                  to: ffprobePath,
                  arguments: [
                    "-v", "error", "-select_streams", "v:0",
                    "-show_entries", "stream=codec_name",
                    "-of", "default=noprint_wrappers=1:nokey=1",
                    inputPath
                  ]
                ).trimmingCharacters(in: .whitespacesAndNewlines)
            }

            let pixFmtTask = Task {
                try shellOut(
                  to: ffprobePath,
                  arguments:
                    [
                      "-v", "error", "-select_streams", "v:0",
                      "-show_entries", "stream=pix_fmt",
                      "-of", "default=noprint_wrappers=1:nokey=1",
                      inputPath
                    ]
                ).trimmingCharacters(in: .whitespacesAndNewlines)
            }

            // The sound goes beside the frames, for a render to put back.  Keeping it never fails the
            // import (see AudioSidecar): a video whose sound cannot be kept comes in without it.
            let sourceHasAudio = await hasAudioTask.value
            let keptAudio = sourceHasAudio ? AudioSidecar.extract(from: inputPath, into: outputFolder) : nil
            let hasAudio = keptAudio != nil

            try await ffmpegTask.value
    
            let frameRateRaw = try await frameRateTask.value

            var frameRate: FrameRate = .fps_24
            let strValue = frameRateRaw.components(separatedBy: "/")[0]
            if let doubleValue = Double(strValue) {
                frameRate = FrameRate(rawValue: doubleValue)
            }

            var codec: FFmpegCodec = .prores
            if let value = FFmpegCodec(rawValue: try await codecTask.value) {
                codec = value
            }

            var pixFmt: FFmpegPixelFormat = .yuv444p10le
            let stringValue = try await pixFmtTask.value
            if let value = FFmpegPixelFormat(rawValue: stringValue) {
                pixFmt = value
            }

            var muxer: FFmpegMuxer = .mov
            if let ext = inputPath.components(separatedBy: ".").last,
               let value = FFmpegMuxer(rawValue: ext)
            {
                muxer = value
            }

            let videoInfo = VideoInfo(
              frameRate: frameRate,
              codec: codec,
              encoder: codec.encoder(for: pixFmt),
              pixelFormat: pixFmt,
              muxer: muxer,
              hasAudio: hasAudio
            )
    

            return (outputFolder, videoInfo)
        } onCancel: {
            ffmpegTask.cancel()
        }
    } catch is CancellationError {
        if createdOutputFolder { try? fileManager.removeItem(atPath: outputFolder) }
        throw CancellationError()
    }
}

public func runFFmpegWithProgress(
  arguments: [String],
  totalFrames: Int?,
  ffmpegPath: String = ToolPaths.ffmpeg,
  outputFolder: String, 
  progress: @escaping ProgressCallback
) throws {
    let run = try FFmpegRun(arguments: arguments,
                            totalFrames: totalFrames,
                            ffmpegPath: ffmpegPath,
                            outputFolder: outputFolder,
                            progress: progress)
    run.process.waitUntilExit()
    try run.finish()
}

/// The same run, as a task that can be cancelled: cancelling it terminates ffmpeg, which stops
/// writing the video, and the call throws `CancellationError`.  (The plain version above blocks its
/// thread until ffmpeg exits whatever happens to the task that called it, so a render the user
/// gave up on ran to the end.)  Whatever ffmpeg had written by then is left where it was written.
public func runCancellableFFmpegWithProgress(
  arguments: [String],
  totalFrames: Int?,
  ffmpegPath: String = ToolPaths.ffmpeg,
  outputFolder: String,
  progress: @escaping ProgressCallback
) async throws {
    try Task.checkCancellation()
    let run = try FFmpegRun(arguments: arguments,
                            totalFrames: totalFrames,
                            ffmpegPath: ffmpegPath,
                            outputFolder: outputFolder,
                            progress: progress)
    await withTaskCancellationHandler {
        await run.exit()
    } onCancel: {
        run.cancel()
    }
    if run.wasCancelled {
        run.stopListening()
        throw CancellationError()
    }
    try run.finish()
}

/// One ffmpeg process, started: the progress it prints on stderr is passed on as it arrives, and
/// all of it is kept for the error message if it fails.
private final class FFmpegRun: @unchecked Sendable {
    let process = Process()
    private let pipe = Pipe()
    private let stderrCollector = StderrCollector()
    private let lock = NSLock()
    private var cancelled = false
    private var handleOutput: @Sendable (Data) -> Void = { _ in }

    var wasCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    init(arguments: [String],
         totalFrames: Int?,
         ffmpegPath: String,
         outputFolder: String,
         progress: @escaping ProgressCallback) throws
    {
        Log.d("starting ffmpeg run with arguments \(arguments)")
        process.executableURL = URL(fileURLWithPath: ffmpegPath)
        // -hide_banner: the banner is the build's whole configure line, which would otherwise
        //   head every error message shown to the user.
        // -nostdin and a null stdin: ffmpeg polls stdin for keypresses ('q' quits), so a child that
        //   inherits a terminal or a pipe takes input meant for whoever else reads it.
        process.arguments = ["-hide_banner", "-nostdin"] + arguments
        process.standardInput = FileHandle.nullDevice
        process.standardError = pipe
        process.standardOutput = nil

        let collector = stderrCollector
        // What ffmpeg prints on stderr: kept for the error message, and the frame count in it is the progress.
        let handle: @Sendable (Data) -> Void = { data in
            collector.append(data)

            if let line = String(data: data, encoding: .utf8) {
                // Match "frame=   123"
                if let range = line.range(of: #"frame=\s*\d+"#, options: .regularExpression) {
                    let numberStr = line[range]
                        .replacingOccurrences(of: "frame=", with: "")
                        .trimmingCharacters(in: .whitespaces)
                    if let frameNum = Int(numberStr) {
                        progress(frameNum, totalFrames ?? 0, outputFolder)
                    }
                }
            }
        }
        handleOutput = handle
        // Typed as @Sendable here rather than left to be inferred from the assignment: Swift 6.0 (CI's, on both macOS and Linux) does not
        // infer it for a closure assigned to this optional property inside an initializer, and rejects the assignment as converting a
        // non-sendable function value.  Newer compilers accept either.
        let onReadable: @Sendable (FileHandle) -> Void = { fileHandle in
            let data = fileHandle.availableData
            guard !data.isEmpty else { return }
            handle(data)
        }
        pipe.fileHandleForReading.readabilityHandler = onReadable

        do {
            try process.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            throw ToolLaunchError(path: ffmpegPath, underlying: error)
        }
    }

    /// Return when the process has exited.
    func exit() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let once = ResumeOnce(continuation)
            process.terminationHandler = { _ in once.resume() }
            // Already gone before the handler was set: it will not be called, so do what it would have.
            if !process.isRunning { once.resume() }
        }
    }

    /// Stop ffmpeg now.  It finishes the file it was writing and exits.
    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
        if process.isRunning { process.terminate() }
    }

    func stopListening() {
        pipe.fileHandleForReading.readabilityHandler = nil
    }

    /// Throw if ffmpeg did not end well; call once it has exited.
    func finish() throws {
        // A short run exits having printed all its progress at the very end, which the handler may not have been given yet:
        // stop it, and take what is left in the pipe.
        stopListening()
        if let rest = try? pipe.fileHandleForReading.readToEnd(), !rest.isEmpty { handleOutput(rest) }

        if process.terminationStatus != 0 {
            let stderrMessage = String(data: stderrCollector.collectedData(), encoding: .utf8) ?? "<unreadable stderr>"
            Log.e("video render failed: \(stderrMessage)")
            throw NSError(
                domain: "ffmpeg",
                code: Int(process.terminationStatus),
                userInfo: [
                    NSLocalizedDescriptionKey: "ffmpeg exited with code \(process.terminationStatus)",
                    "stderr": stderrMessage
                ]
            )
        }
        Log.d("ending ffmpeg run")
    }
}

/// Resumes a continuation the first time it is asked to and never again, so two things that can both
/// say "the process is done" cannot resume it twice.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?

    init(_ continuation: CheckedContinuation<Void, Never>) { self.continuation = continuation }

    func resume() {
        lock.lock()
        let taken = continuation
        continuation = nil
        lock.unlock()
        taken?.resume()
    }
}

final class StderrCollector: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()

    func append(_ newData: Data) {
        lock.lock()
        data.append(newData)
        lock.unlock()
    }

    func collectedData() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}


/// How many frames the first video stream has, or 0 if it cannot be told.  Tries the header first (instant; an estimate from duration
/// and rate when the container has no count), then counts packets (no decoding), and only then decodes the whole video.
func videoFrameCount(of path: String, ffprobePath: String) -> Int {
    if let count = VideoProbe.probe(videoAt: path)?.frameCount, count > 0 {
        Log.i("frame count from header: \(count)")
        return count
    }
    for (flag, key) in [("-count_packets", "nb_read_packets"), ("-count_frames", "nb_read_frames")] {
        let output = try? shellOut(
          to: ffprobePath,
          arguments: [
            "-v", "error", flag, "-select_streams", "v:0",
            "-show_entries", "stream=\(key)",
            "-of", "default=noprint_wrappers=1:nokey=1",
            path
          ])
        if let count = output.flatMap({ Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }), count > 0 {
            Log.i("frame count from \(flag): \(count)")
            return count
        }
    }
    return 0
}
