import Foundation
import logging

/// Renders a finished sequence's output frames to a video with ffmpeg, the way the daemon's `Export.Video` does: a concat list of
/// exactly the frames processing wrote (see `VideoExport`), encoded with the config's video settings.  Those are the imported
/// video's when the sequence came from one, else `Config`'s defaults (30 fps, ProRes, `.mov`).
///
/// - Parameters:
///   - sourceFilenames: the sequence's input file names or paths in frame order; the output frames carry the same names.
///   - videoPath: where to write; nil is `VideoExport.defaultOutputPath`.
/// - Returns: the path written.  Throws when no output frame exists or ffmpeg fails.
@discardableResult
public func renderOutputVideo(
    config: Config,
    sourceFilenames: [String],
    videoPath: String? = nil,
    progress: @escaping ProgressCallback = { _, _, _ in }
) async throws -> String {
    let videoInfo = VideoInfo(frameRate: config.frameRate, codec: config.codec, encoder: config.encoder,
                              pixelFormat: config.pixelFormat, muxer: config.muxer, hasAudio: config.hasAudio)
    guard videoInfo.frameRate.rawValue > 0 else { throw "invalid frame rate \(videoInfo.frameRate.rawValue)" }
    guard ToolPaths.isAvailable else {
        throw "ffmpeg and ffprobe are needed to render a video, but none were found. Looked for them in $\(ToolPaths.directoryOverrideVariable), beside the executable, external_binaries/bin of a build tree, then on PATH."
    }

    let target = videoPath ?? VideoExport.defaultOutputPath(config: config, muxer: videoInfo.muxer)
    let frameDir = config.outputSequenceDirname
    let found = VideoExport.finalFrames(outputDir: frameDir, sourceFilenames: sourceFilenames)
    guard !found.files.isEmpty else { throw "nothing to render: no processed frames found in \(frameDir)" }
    if !found.missing.isEmpty {
        Log.w("render video: \(found.missing.count) of \(sourceFilenames.count) frames have no output in \(frameDir) and are left out")
    }

    let decodedDir = (sourceFilenames.first.map { ($0 as NSString).deletingLastPathComponent }) ?? config.outputPath
    let audio = videoInfo.hasAudio
      ? AudioSidecar.plan(in: decodedDir, formatArguments: ["-f", videoInfo.muxer.rawValue], outputExtension: "")
      : AudioPlan.none("the video has none")

    try FileManager.default.createDirectory(
        atPath: (target as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    let listPath = NSTemporaryDirectory() + "/star-render-\(UUID().uuidString).ffconcat"
    try VideoExport.concatList(files: found.files, frameRate: videoInfo.frameRate)
        .write(toFile: listPath, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(atPath: listPath) }

    let args = VideoExport.arguments(listPath: listPath, audio: audio, videoInfo: videoInfo, outputVideoPath: target)
    try await runCancellableFFmpegWithProgress(arguments: args, totalFrames: found.files.count,
                                               outputFolder: config.outputPath, progress: progress)
    return target
}

/// Extensions the cli (and the desktop's file chooser) treat as a video rather than an image sequence directory.
public let videoFileExtensions: Set<String> = ["mov", "mp4", "m4v", "avi", "mkv", "mpg", "mpeg"]

public func isVideoFile(path: String) -> Bool {
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else { return false }
    return videoFileExtensions.contains((path as NSString).pathExtension.lowercased())
}
