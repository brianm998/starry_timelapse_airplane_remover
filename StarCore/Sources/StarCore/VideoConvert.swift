import Foundation
import ShellOut
import logging

public typealias ProgressCallback = @Sendable (_ currentFrame: Int, _ totalFrames: Int) -> Void

/// Process a video: extract frames and audio, and generate a reencode script
public func decodeVideo(
    named inputPath: String,
    progress: @escaping ProgressCallback
) async throws -> (outputDirectory: String, reencodeScript: String) {
    let inputURL = URL(fileURLWithPath: inputPath)
    let fileName = inputURL.deletingPathExtension().lastPathComponent
    let fileExtension = inputURL.pathExtension
    let outputFolder = inputURL.deletingLastPathComponent().appendingPathComponent(fileName).path
    let reencodeScriptDir = inputURL.deletingLastPathComponent().path
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
    let frameRate = frameRateRaw.components(separatedBy: "/")[0]

    let codec = try await codecTask.value

    let pixFmt = try await pixFmtTask.value
    
    /*
     XXX instead of generating a script here,
     save the codec, pixel format, filename, frame rate and audio track presence in config
     use that later as defaults in the RenderVideoSheetView UI
     */
    // Generate re-encode script
    let reencodeScriptPath = "\(reencodeScriptDir)/reencode-\(fileName).sh"
    var script = """
    #!/bin/bash

    set -e

    PROCESSED_FILES_DIR=$1
    
    \(ffmpegPath) -framerate \(frameRate) -f image2 -i "$PROCESSED_FILES_DIR"/image_%04d.tiff \\
      -c:v \(codec) -pix_fmt \(pixFmt)
    """
    if hasAudio {
        script += " \\\n  -i audio.aac -c:a copy"
    }
    script += " \\\n  \(fileName)_reencoded.\(fileExtension)\n"

    try script.write(toFile: reencodeScriptPath, atomically: true, encoding: .utf8)
    try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: reencodeScriptPath)

    return (outputFolder, reencodeScriptPath)
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
