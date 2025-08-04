import Foundation
import ShellOut
import logging

public typealias ProgressCallback = @Sendable (_ currentFrame: Int, _ totalFrames: Int) -> Void

public struct VideoInfo: Sendable {
    public let frameRate: FrameRate
    public let codec: FFmpegCodec
    public let pixelFormat: FFmpegPixelFormat
    public let muxer: FFmpegMuxer
    public let hasAudio: Bool
}

/// Process a video: extract frames and audio and video information
public func decodeVideo(
    named inputPath: String,
    progress: @escaping ProgressCallback
) async throws -> (outputDirectory: String, videoInfo: VideoInfo) {
    let inputURL = URL(fileURLWithPath: inputPath)
    let fileName = inputURL.deletingPathExtension().lastPathComponent
    let fileExtension = inputURL.pathExtension
    let outputFolder = inputURL.deletingLastPathComponent().appendingPathComponent(fileName).path
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
    let totalFrames = Int(totalFramesStr.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0

    let ffmpegTask = Task {
        try runFFmpegWithProgress(
          arguments: ["-i", inputPath, "-pix_fmt", "rgb48le", "\(outputFolder)/image_%04d.tiff"],
          totalFrames: totalFrames,
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
  progress: @escaping ProgressCallback
) throws {
    Log.d("starting ffmpeg run")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: ffmpegPath)
    process.arguments = arguments

    let pipe = Pipe()
    process.standardError = pipe
    process.standardOutput = nil

    let stderrCollector = StderrCollector()

    pipe.fileHandleForReading.readabilityHandler = { handle in
        let data = handle.availableData
        guard !data.isEmpty else { return }

        stderrCollector.append(data)

        if let line = String(data: data, encoding: .utf8) {
            // Match "frame=   123"
            if let range = line.range(of: #"frame=\s*\d+"#, options: .regularExpression) {
                let numberStr = line[range]
                    .replacingOccurrences(of: "frame=", with: "")
                    .trimmingCharacters(in: .whitespaces)
                if let frameNum = Int(numberStr) {
                    progress(frameNum, totalFrames ?? 0)
                }
            }
        }
    }

    try process.run()
    process.waitUntilExit()
    pipe.fileHandleForReading.readabilityHandler = nil

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

final class StderrCollector: @unchecked Sendable {
    private var data = Data()
    private let queue = DispatchQueue(label: "stderr.sync.queue")

    func append(_ newData: Data) {
        queue.sync {
            data.append(newData)
        }
    }

    func collectedData() -> Data {
        queue.sync { data }
    }
}


public func OLD_runFFmpegWithProgress(
  arguments: [String],
  totalFrames: Int?,
  ffmpegPath: String = ToolPaths.ffmpeg,
  progress: @escaping ProgressCallback
) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: ffmpegPath)
    process.arguments = arguments

    let pipe = Pipe()
    process.standardError = pipe
    process.standardOutput = nil

    pipe.fileHandleForReading.readabilityHandler = { handle in
        let data = handle.availableData
        guard let line = String(data: data, encoding: .utf8) else { return }

        // Match "frame=   123"
        if let range = line.range(of: #"frame=\s*\d+"#, options: .regularExpression) {
            let numberStr = line[range]
              .replacingOccurrences(of: "frame=", with: "")
              .trimmingCharacters(in: .whitespaces)
            if let frameNum = Int(numberStr) {
                progress(frameNum, totalFrames ?? 0)
            }
        }
    }

    try process.run()
    process.waitUntilExit()
    pipe.fileHandleForReading.readabilityHandler = nil

    if process.terminationStatus != 0 {
        throw NSError(
          domain: "ffmpeg",
          code: Int(process.terminationStatus),
          userInfo: [
            NSLocalizedDescriptionKey: "ffmpeg exited with code \(process.terminationStatus)"
          ]
        )
    }
}
