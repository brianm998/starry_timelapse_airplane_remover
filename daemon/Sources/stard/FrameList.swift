import Foundation
import StarCore

/// The frames of a video export, given to ffmpeg as a list.
///
/// An export used to read `<folder>/image_%04d.tiff`, which are the names `decodeVideo` gives the
/// frames of a video it takes apart.  A session opened from a folder of images keeps the names
/// those images had (`IMG_0412.tif`, `night sky 12.png`, ...), which that matches none of, so every
/// export of one failed.  A pattern that counts is a poor fit even for the sequences it does suit:
/// at the first number missing ffmpeg stops reading, logs a line, and exits successfully, so a
/// video cut short was reported as done.  And the other way it has of reading files by name,
/// `-pattern_type glob` (which the Mac app uses), needs the C library's `glob()`, which Windows lacks.
///
/// So the frames are listed.  ffmpeg's concat demuxer reads a list of files in the order given,
/// whatever they are called, with any gaps between them, and with the list in a file there is
/// no limit to how many.  Measured on 6000x4000 16-bit LZW TIFFs, decoding through a list took the
/// same time as through a numbered pattern, and for every frame rate star offers, `-r` made the
/// same video: the same frame count, frame rate and duration.
///
/// What it does ask is that the frames are all one kind of image file, which they are in any
/// sequence star has processed (it takes the kind from the first image): ffmpeg decodes every
/// frame as the first one, so a `.png` among the `.tif` is left out of the video.
enum FrameList {

    /// A name that cannot be written in a list, because the list is one frame to a line.
    struct UnlistableName: Error, CustomStringConvertible {
        let path: String
        var description: String { "the frame file name \(path.debugDescription) contains a line break" }
    }

    /// Where a render leaves the finished image of the input frame `input`: in `folder`, under the
    /// name the input had.
    static func renderedPath(of input: String, in folder: String) -> String {
        "\(folder)/\(removePath(fromString: input))"
    }

    /// The finished images of `inputs` that a render has left in `folder`, in the order of the
    /// inputs.  A frame that has not been rendered is left out, not waited for.
    static func renderedFrames(of inputs: [String],
                               in folder: String,
                               exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> [String]
    {
        inputs.map { renderedPath(of: $0, in: folder) }.filter(exists)
    }

    /// The list, in ffmpeg's concat script syntax, of `paths` in the order given.
    ///
    /// Paths are written absolute, because ffmpeg reads a relative one as relative to the list file,
    /// which is somewhere else.
    static func script(for paths: [String]) throws -> String {
        var lines = ["ffconcat version 1.0"]
        lines.reserveCapacity(paths.count + 1)
        for path in paths {
            if path.contains("\n") || path.contains("\r") {
                throw UnlistableName(path: path)
            }
            lines.append("file \(quoted(URL(fileURLWithPath: path).path))")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// A path as one token of the script.  Everything inside single quotes is taken literally,
    /// backslashes of a Windows path included; the one character that cannot be inside them is a
    /// single quote, which is written outside, escaped.
    static func quoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The ffmpeg options that read the list at `listPath` as one video at `frameRate`, to go
    /// before the next `-i`.
    ///
    /// `-r` as an input option is what gives the video its speed: it makes the timestamps up from
    /// the rate instead of taking them from the files, which for a list of single images are all
    /// the same.  `-safe 0` is what lets the list name files by absolute path.
    static func inputArguments(listPath: String, frameRate: String) -> [String] {
        ["-r", frameRate, "-f", "concat", "-safe", "0", "-i", listPath]
    }
}
