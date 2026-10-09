import Foundation
import StarCore

// What `Export.Video` hands to ffmpeg, kept apart from the handler so the file naming and the
// command line can be tested without running an encode.
//
// Processing writes each final frame to `<Config.outputSequenceDirname>/<source file name>`:
// the source frame's own name and extension, in a directory named after the sequence
// (`<outputPath>/seq-star-v-0_12_1/LRT_00080.tif`).  A video import decodes to
// `<video dir>/<name>/image_%04d.tiff`, and its output frames keep those names the same way.
// The names are whatever the camera or the decoder made, and the numbers in them need not start
// at 1 or be contiguous, so there is no `%04d` pattern that fits them all; and ffmpeg's `glob`
// pattern type, which the macOS gui uses, is not built into the Windows ffmpeg.  The frames
// therefore reach ffmpeg as a concat list of exactly the files the session expects, in frame
// order.
enum VideoExport {

    /// The final frames of a session, split by whether processing has written them.
    struct FinalFrames {
        /// Full paths of the frames on disk, in frame order.
        let files: [String]
        /// File names the session expects in the output directory but did not find there.
        let missing: [String]
    }

    /// Looks for each of the session's frames in `outputDir`.
    ///
    /// `sourceFilenames` are the sequence's file names or paths, in frame order; only the last
    /// path component of each is used, because that is the name the output frame carries.
    static func finalFrames(
        outputDir: String,
        sourceFilenames: [String],
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> FinalFrames {
        var files: [String] = []
        var missing: [String] = []
        for source in sourceFilenames {
            let name = (source as NSString).lastPathComponent
            let path = "\(outputDir)/\(name)"
            if fileExists(path) {
                files.append(path)
            } else {
                missing.append(name)
            }
        }
        return FinalFrames(files: files, missing: missing)
    }

    /// The contents of an ffmpeg concat-demuxer list for `files`, one frame each.
    ///
    /// Each entry says how long its frame lasts twice over, and both are needed.  `duration`
    /// spaces the frames' timestamps `1/frameRate` apart.  `option framerate` goes to the image
    /// demuxer that reads the file, which otherwise stamps every frame with a default 25 fps
    /// length of its own, and ffmpeg's constant-frame-rate output trusts that length over the
    /// spacing: at 24 and 25 fps that is harmless, but from 29.97 up it duplicates frames, up to
    /// one at the start and one at the end (a 40-frame list made 41 frames at 30 fps and 42 at
    /// 60).  With both, the output has exactly one frame per entry at every rate.
    static func concatList(files: [String], frameRate: FrameRate) -> String {
        let rate = frameRate.rawString
        let duration = String(format: "%.9f", 1.0 / frameRate.rawValue)
        var list = "ffconcat version 1.0\n"
        for file in files {
            list += "file \(quoted(file))\noption framerate \(rate)\nduration \(duration)\n"
        }
        return list
    }

    /// `path` as a single-quoted concat-list token.  Inside the quotes ffmpeg reads every
    /// character literally — backslashes in a Windows path included — except the quote itself,
    /// which is closed, escaped and reopened.
    static func quoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The video's path when the client did not choose one: next to the output sequence's
    /// directory, named after it, in the chosen container.  The macOS gui's render sheet
    /// defaults to the same name.
    static func defaultOutputPath(config: Config, muxer: FFmpegMuxer) -> String {
        "\(config.outputPath)/\(config.basename).\(muxer.rawValue)"
    }

    /// The ffmpeg command line that encodes the frames listed in `listPath` — plus the audio
    /// track at `audioPath`, when there is one — to `outputVideoPath`.
    ///
    /// `-r` follows the inputs, so it is the output frame rate: with the list's per-frame
    /// durations it gives exactly one output frame per image in constant-frame-rate
    /// containers, and sets the stream's rate in the others.
    static func arguments(
        listPath: String,
        audioPath: String?,
        videoInfo: VideoInfo,
        outputVideoPath: String
    ) -> [String] {
        let encoderName = videoInfo.encoder?.rawValue ?? videoInfo.codec.rawValue

        var args = ["-f", "concat", "-safe", "0", "-i", listPath]
        if let audioPath { args += ["-i", audioPath] }
        args += [
            "-r", videoInfo.frameRate.rawString,
            "-c:v", encoderName,
            "-pix_fmt", videoInfo.pixelFormat.rawValue,
        ]
        if audioPath != nil { args += ["-c:a", "copy"] }
        args += ["-f", videoInfo.muxer.rawValue, "-y", outputVideoPath]
        return args
    }
}
