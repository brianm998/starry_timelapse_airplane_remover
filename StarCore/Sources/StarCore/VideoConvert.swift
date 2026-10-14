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

    public init(frameRate: FrameRate, codec: FFmpegCodec, encoder: FFmpegEncoder?,
                pixelFormat: FFmpegPixelFormat, muxer: FFmpegMuxer, hasAudio: Bool) {
        self.frameRate = frameRate
        self.codec = codec
        self.encoder = encoder
        self.pixelFormat = pixelFormat
        self.muxer = muxer
        self.hasAudio = hasAudio
    }
}


/// Process a video: extract frames and audio and video information
public func decodeVideo(
    named inputPath: String,
    progress: @escaping ProgressCallback
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

    try? fileManager.createDirectory(atPath: outputFolder, withIntermediateDirectories: true)

    let ffprobePath = ToolPaths.ffprobe
    let ffmpegPath = ToolPaths.ffmpeg

    let totalFramesTask = Task {
        try shellOut(
          to: ffprobePath,
          arguments: [
            "-v", "error", "-count_frames", "-select_streams", "v:0",
            "-show_entries", "stream=nb_read_frames",
            "-of", "default=noprint_wrappers=1:nokey=1",
            inputPath
          ]
        )
    }
    let totalFramesStr = try await totalFramesTask.value

    // XXX report counting frames here
    
    let totalFrames = Int(totalFramesStr.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0

    // On macOS decode on the GPU/media engine (VideoToolbox) where the codec supports it;
    // ffmpeg falls back to software decoding on its own where it doesn't.
    #if os(macOS)
    let decodeArguments = ["-hwaccel", "videotoolbox"]
    #else
    let decodeArguments: [String] = []
    #endif

    let ffmpegTask = Task {
        try runFFmpegWithProgress(
          arguments: decodeArguments + ["-i", inputPath, "-pix_fmt", "rgb48le", "\(outputFolder)/image_%04d.tiff"],
          totalFrames: totalFrames,
          outputFolder: outputFolder,
          progress: progress
        )
    }

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

    let hasAudio = await hasAudioTask.value

    if hasAudio {
        _ = try shellOut(to: ffmpegPath, arguments: [
            "-i", inputPath, "-vn", "-acodec", "copy", "\(outputFolder)/audio.aac"
        ])
    }

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
        process.arguments = arguments
        process.standardError = pipe
        process.standardOutput = nil

        let collector = stderrCollector
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }

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

        try process.run()
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
        stopListening()

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
