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


/// What describes a video apart from its pictures: frame rate, codec, pixel format, container, and whether its sound was kept.
/// The sound, if there is any, goes beside the frames (`AudioSidecar`) in its own codec where that is possible; keeping it never
/// fails the import, so a video whose sound cannot be kept comes in without it.
public func readVideoInfo(named inputPath: String, outputFolder: String) async throws -> VideoInfo {
    let ffprobePath = ToolPaths.ffprobe

    func probe(_ entry: String, stream: String = "v:0") -> Task<String, Error> {
        Task {
            try await shellOutOffPool(
              to: ffprobePath,
              arguments: [
                "-v", "error", "-select_streams", stream,
                "-show_entries", entry,
                "-of", "default=noprint_wrappers=1:nokey=1",
                inputPath
              ]
            ).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
    let hasAudioTask = Task {
        (try? await shellOutOffPool(
           to: ffprobePath,
           arguments: [
             "-v", "error", "-select_streams", "a:0",
             "-show_entries", "stream=codec_type",
             "-of", "default=noprint_wrappers=1:nokey=1",
             inputPath
           ]
         ).trimmingCharacters(in: .whitespacesAndNewlines)) == "audio"
    }
    let frameRateTask = probe("stream=r_frame_rate")
    let codecTask = probe("stream=codec_name")
    let pixFmtTask = probe("stream=pix_fmt")

    // The sound goes beside the frames, for a render to put back.
    let sourceHasAudio = await hasAudioTask.value
    let keptAudio = sourceHasAudio ? AudioSidecar.extract(from: inputPath, into: outputFolder) : nil
    let hasAudio = keptAudio != nil

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

    return VideoInfo(
      frameRate: frameRate,
      codec: codec,
      encoder: codec.encoder(for: pixFmt),
      pixelFormat: pixFmt,
      muxer: muxer,
      hasAudio: hasAudio
    )
}

/// Process a video: extract frames and audio and video information, and return once all of it is on disk.
/// The audio, if it has any, is kept beside the frames by `AudioSidecar`, in its own codec where that is possible.
///
/// This is the in-order extraction of `VideoFrameSource` run to the end; a client that wants to start before that, or to say which
/// frames it needs first, starts a source with `startVideoExtraction` instead.
public func decodeVideo(
    named inputPath: String,
    format: FrameDecodeFormat = .tiff16,
    framesParentFolder: String? = nil,
    progress progressCallback: @escaping ProgressCallback
) async throws -> (outputDirectory: String, videoInfo: VideoInfo) {
    let ffmpegPath = ToolPaths.ffmpeg
    Log.i("decoding \(inputPath) with ffmpeg at \(ffmpegPath)")

    // The frame count is only the denominator of the extraction progress here, so it is not worth a packet count: the header's
    // (an estimate when the container has no count) will do, and a bar past its end is clamped.
    let source = try await VideoFrameSource.make(videoPath: inputPath, format: format, settings: .sweepOnly, requireExactCount: false, framesParentFolder: framesParentFolder)
    let outputFolder = source.outputFolder
    let fileManager = FileManager.default

    // A decode that is given up on takes back what it made, and only that: frames left half written would make the next attempt at
    // the same video find a folder it did not make.
    func giveUp() {
        source.stop()
        if source.createdOutputFolder { try? fileManager.removeItem(atPath: outputFolder) }
    }

    let reporting = Task {
        var highest = 0
        for await event in source.events() {
            switch event {
            case .snapshot(_, _, let state), .progress(let state):
                if state.extracted > highest {
                    highest = state.extracted
                    progressCallback(highest, max(state.total, highest), outputFolder)
                }
            default: break
            }
        }
    }
    defer { reporting.cancel() }

    do {
        return try await withTaskCancellationHandler {
            let infoTask = Task { try await readVideoInfo(named: inputPath, outputFolder: outputFolder) }
            do {
                try await source.waitUntilFinished()
                guard source.progress.isComplete else { throw CancellationError() }
                // The events are delivered on their own task, which a short video can be finished before it has seen.
                let final = source.progress
                progressCallback(final.extracted, max(final.total, final.extracted), outputFolder)
            } catch {
                infoTask.cancel()
                throw error
            }
            return (outputFolder, try await infoTask.value)
        } onCancel: {
            source.stop()
        }
    } catch is CancellationError {
        giveUp()
        throw CancellationError()
    } catch let error as FrameSourceError {
        // ffmpeg's own message, as it always was.
        throw error
    }
}

/// Starts extracting a video's frames in the background and returns once the first frame is on disk, with the video's
/// description (and its sound, kept beside the frames).  The rest of the frames arrive while the caller goes on; ask the returned
/// source which are there and which it wants first.  Throws `CancellationError`, taking back the folder this made, if the caller
/// gives up before that.
public func startVideoExtraction(
    named inputPath: String,
    format: FrameDecodeFormat = .tiff16,
    settings: FrameExtractionSettings = .default,
    framesParentFolder: String? = nil
) async throws -> (source: VideoFrameSource, videoInfo: VideoInfo) {
    let source = try await VideoFrameSource.make(videoPath: inputPath, format: format, settings: settings, framesParentFolder: framesParentFolder)
    func giveUp() {
        source.stop()
        if source.createdOutputFolder { try? FileManager.default.removeItem(atPath: source.outputFolder) }
    }
    do {
        return try await withTaskCancellationHandler {
            let infoTask = Task { try await readVideoInfo(named: inputPath, outputFolder: source.outputFolder) }
            do {
                try await source.waitUntilAvailable(0)
            } catch {
                infoTask.cancel()
                throw error
            }
            return (source, try await infoTask.value)
        } onCancel: {
            source.stop()
        }
    } catch is CancellationError {
        giveUp()
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
final class FFmpegRun: @unchecked Sendable {
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
            // Empty data is end of file: ffmpeg has closed its end.  A pipe at end of file stays readable for ever, so a handler that
            // merely returns is called again at once, in a loop, until someone removes it.  That someone is `finish()`, which only runs
            // once `exit()` has been resumed on the cooperative pool; if the pool is busy (see `shellOutOffPool`) the loop starves the
            // dispatch workers the probes need and the whole import stops, with a core at 100% (hosted 3-CPU macOS runners, BUG-006).
            guard !data.isEmpty else { fileHandle.readabilityHandler = nil; return }
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
    ///
    /// Asked politely first (SIGTERM), then not: measured, a decode of a big ProRes file that has been told to stop this way goes
    /// on decoding and writing frames for as long as it is left (a stopped sweep kept running for 37 minutes, writing frames nobody
    /// collected), where the short runs a jump makes do exit on it.  So a process that is still there `killGrace` seconds later is
    /// killed.
    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
        guard process.isRunning else { return }
        process.terminate()
        #if !os(Windows)
        let process = self.process
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Self.killGrace) {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        #endif
    }

    /// Seconds a stopped ffmpeg is given to exit by itself.
    static let killGrace: TimeInterval = 2

    /// Kill ffmpeg now, without asking: for a process that is exiting and cannot wait.
    func killNow() {
        lock.lock()
        cancelled = true
        lock.unlock()
        #if !os(Windows)
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        #else
        if process.isRunning { process.terminate() }
        #endif
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


/// `shellOut` without holding a thread of Swift's cooperative pool while the child runs.  The pool is as wide as the machine has cores,
/// and `shellOut` blocks its thread until the child exits; a few of those at once on a 3-CPU machine take the whole pool, so nothing
/// that has to be resumed on it (the end of an ffmpeg run, say) can run, and a probe that is waiting for that blocks for ever.
func shellOutOffPool(to executable: String, arguments: [String]) async throws -> String {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            do { continuation.resume(returning: try shellOut(to: executable, arguments: arguments)) }
            catch { continuation.resume(throwing: error) }
        }
    }
}

/// How many frames the first video stream has, or 0 if it cannot be told.  Tries the header first (instant; an estimate from duration
/// and rate when the container has no count), then counts packets (no decoding), and only then decodes the whole video.
func videoFrameCount(of path: String, ffprobePath: String) -> Int {
    if let count = VideoProbe.probe(videoAt: path)?.frameCount, count > 0 {
        Log.i("frame count from header: \(count)")
        return count
    }
    return videoPacketCount(of: path, ffprobePath: ffprobePath) ?? 0
}

/// The video stream's frame count the exact ways: a packet count, which demuxes without decoding, and only then a decode of
/// everything.  nil if neither says.
func videoPacketCount(of path: String, ffprobePath: String) -> Int? {
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
    return nil
}
