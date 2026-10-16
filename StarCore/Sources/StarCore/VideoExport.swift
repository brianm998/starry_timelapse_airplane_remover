import Foundation

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
public enum VideoExport {

    /// The final frames of a session, split by whether processing has written them.
    public struct FinalFrames {
        /// Full paths of the frames on disk, in frame order.
        public let files: [String]
        /// File names the session expects in the output directory but did not find there.
        public let missing: [String]
    }

    /// Looks for each of the session's frames in `outputDir`.
    ///
    /// `sourceFilenames` are the sequence's file names or paths, in frame order; only the last
    /// path component of each is used, because that is the name the output frame carries.
    public static func finalFrames(
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
    ///
    /// The list is a line to a directive, so a name with a line break in it cannot be written: it
    /// is refused, not written as two lines that mean something else.
    public static func concatList(files: [String], frameRate: FrameRate) throws -> String {
        let rate = frameRate.rawString
        let duration = String(format: "%.9f", 1.0 / frameRate.rawValue)
        var list = "ffconcat version 1.0\n"
        for file in files {
            if file.contains("\n") || file.contains("\r") { throw UnlistableName(path: file) }
            list += "file \(quoted(file))\noption framerate \(rate)\nduration \(duration)\n"
        }
        return list
    }

    /// A name that cannot be written in a list, because the list is one directive to a line.
    public struct UnlistableName: Error, CustomStringConvertible {
        public let path: String
        public var description: String { "the frame file name \(path.debugDescription) contains a line break" }
    }

    /// `path` as a single-quoted concat-list token.  Inside the quotes ffmpeg reads every
    /// character literally — backslashes in a Windows path included — except the quote itself,
    /// which is closed, escaped and reopened.
    public static func quoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// `values` with the entries named in `preferred` moved to the front, in that order; the
    /// rest keep their relative order.  The Render Video dialog opens on the first entry of
    /// each list, and the capability graph is generated alphabetically, so an unordered list
    /// opens on `a64` (the Commodore 64 muxer, which cannot hold h264 at all) and on whichever
    /// pixel format sorts first, which ffmpeg then cannot write a header for.
    public static func prioritized(_ values: [String], preferred: [String]) -> [String] {
        preferred.filter(values.contains) + values.filter { !preferred.contains($0) }
    }

    public static let preferredMuxers = ["mp4", "mov", "matroska", "webm", "avi"]
    public static let preferredPixelFormats = ["yuv420p", "yuv420p10le", "yuv422p", "yuv444p"]

    /// The video's path when the client did not choose one: next to the output sequence's
    /// directory, named after it, in the chosen container.  The macOS gui's render sheet
    /// defaults to the same name.  The extension is the container's own, not its muxer name:
    /// Matroska's muxer is called `matroska` and its files are `.mkv`, and a file named
    /// `.matroska` opens in nothing.
    public static func defaultOutputPath(config: Config, muxer: FFmpegMuxer) -> String {
        "\(config.outputPath)/\(config.basename).\(muxer.defaultFileExtension ?? muxer.rawValue)"
    }

    /// The ffmpeg command line that encodes the frames listed in `listPath` — plus the video's
    /// own sound, as `audio` plans it — to `outputVideoPath`, in the container `videoInfo` names.
    ///
    /// `-r` follows the inputs, so it is the output frame rate: with the list's per-frame
    /// durations it gives exactly one output frame per image in constant-frame-rate
    /// containers, and sets the stream's rate in the others.
    public static func arguments(
        listPath: String,
        audio: AudioPlan,
        videoInfo: VideoInfo,
        outputVideoPath: String
    ) -> [String] {
        let encoderName = videoInfo.encoder?.rawValue ?? videoInfo.codec.rawValue

        var args = ["-f", "concat", "-safe", "0", "-i", listPath]
        args += audio.inputArguments
        args += [
            "-r", videoInfo.frameRate.rawString,
            "-c:v", encoderName,
            "-pix_fmt", videoInfo.pixelFormat.rawValue,
        ]
        // for the GPU encoders whose own default quality is poor (see FFmpegHardware.swift)
        args += videoInfo.encoder?.defaultQualityArguments ?? []
        args += audio.codecArguments
        args += ["-f", videoInfo.muxer.rawValue, "-y", outputVideoPath]
        return args
    }
}
