import Foundation
import logging

/// What a video's structure says about how cheaply one frame can be had on its own.
///
/// Measured (memory `video-direct-decode-costs`): a random frame of 4K HEVC/H.264 (GOP 60) costs 1.3-2.7 s, because it decodes
/// about 28 frames per seek, and a random ProRes frame costs 0.22 s at 4K.  Sequential decode is 53-190 ms a frame, most of it the
/// YUV to rgb48 conversion.
public enum VideoAccess {

    /// A guess from the codec's name alone, for a dialog that must not wait on a probe.
    public static func guess(fromCodecName name: String?) -> FrameAccessKind {
        guard let name = name?.lowercased() else { return .longGOP }
        let intraOnly: Set<String> = [
            "prores", "dnxhd", "dnxhr", "mjpeg", "cfhd", "ffv1", "huffyuv", "utvideo", "rawvideo", "png", "tiff", "jpeg2000",
            "v210", "v410", "qtrle", "magicyuv", "prores_ks", "dpx", "exr",
        ]
        return intraOnly.contains(name) ? .seekable : .longGOP
    }

    /// Whether the first packets of the video stream are all keyframes: true for ProRes, DNxHD/HR, MJPEG, intra HEVC/H.264,
    /// CineForm and so on, without a codec list.  Reads the packet headers only, so it is quick even for a long file.  nil when
    /// ffprobe could not say.
    public static func isIntraOnly(videoAt path: String) -> Bool? {
        guard let output = try? shellOut(
          to: ToolPaths.ffprobe,
          arguments: [
            "-v", "error", "-select_streams", "v:0",
            "-read_intervals", "%+#\(packetsToExamine)",
            "-show_entries", "packet=flags",
            "-of", "csv=p=0",
            path
          ]) else { return nil }
        return intraOnly(packetFlagsOutput: output)
    }

    /// Packets the check reads: enough to see a GOP (a long-GOP video has a P frame in the first few).
    static let packetsToExamine = 300

    static func intraOnly(packetFlagsOutput output: String) -> Bool? {
        let lines = output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }
        return lines.allSatisfy { $0.contains("K") }
    }

    /// The kind to use: the packet probe when it answered, else the codec's name.
    public static func accessKind(videoAt path: String, codecName: String?) -> FrameAccessKind {
        if let intra = isIntraOnly(videoAt: path) { return intra ? .seekable : .longGOP }
        return guess(fromCodecName: codecName)
    }
}

/// When each frame of a video is shown, in frame order, so that a jump can seek to the right one.
///
/// Real timestamps, not `index / fps`: variable frame rate and odd start times would otherwise land a jump a frame off and write
/// the wrong picture under the right name, silently.
public struct VideoFrameTimes: Sendable, Equatable {
    /// Presentation times in seconds, ascending: frame `i` is shown at `times[i]`.
    public let times: [Double]
    /// The container's start time, which ffmpeg's input `-ss` is relative to.
    public let startTime: Double

    public init(times: [Double], startTime: Double = 0) {
        self.times = times.sorted()
        self.startTime = startTime
    }

    public var count: Int { times.count }

    /// The `-ss` value that makes ffmpeg's first output frame be frame `index`: between the previous frame and this one, so that
    /// rounding in either the table or ffmpeg cannot tip it a frame either way.
    public func seekTime(forFrame index: Int) -> Double {
        guard !times.isEmpty else { return 0 }
        let i = min(max(index, 0), times.count - 1)
        let here = times[i]
        let before = i > 0 ? times[i - 1] : here - 0.001
        // A frame at the very start needs no seek (and a negative one would be an error).
        return max(0, (before + here) / 2 - startTime)
    }

    /// Reads the table by demuxing (no decoding), or nil when the file gives no usable timestamps.
    public static func read(videoAt path: String, expectedFrames: Int?) -> VideoFrameTimes? {
        guard let packets = try? shellOut(
          to: ToolPaths.ffprobe,
          arguments: ["-v", "error", "-select_streams", "v:0", "-show_entries", "packet=pts_time", "-of", "csv=p=0", path])
        else { return nil }
        let start = (try? shellOut(
          to: ToolPaths.ffprobe,
          arguments: ["-v", "error", "-show_entries", "format=start_time", "-of", "default=noprint_wrappers=1:nokey=1", path]))
            .flatMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 0
        return parse(packetOutput: packets, startTime: start, expectedFrames: expectedFrames)
    }

    static func parse(packetOutput: String, startTime: Double, expectedFrames: Int?) -> VideoFrameTimes? {
        var times: [Double] = []
        for line in packetOutput.split(whereSeparator: \.isNewline) {
            // `N/A` for a packet without a timestamp, and a trailing comma where ffprobe adds another field.
            let field = line.split(separator: ",").first.map(String.init) ?? ""
            if let value = Double(field.trimmingCharacters(in: .whitespaces)) { times.append(value) }
        }
        guard !times.isEmpty else { return nil }
        let table = VideoFrameTimes(times: times, startTime: startTime)
        // A table that does not match the frame count is a table of something else (an audio-like stream, dropped packets):
        // seeking by it would land on the wrong frames.
        if let expectedFrames, expectedFrames > 0, table.count != expectedFrames { return nil }
        return table
    }

    /// `index / rate`, for a video whose timestamps could not be read.  Only as good as the video is constant frame rate.
    public static func evenlySpaced(frameCount: Int, framesPerSecond: Double) -> VideoFrameTimes {
        let rate = framesPerSecond > 0 ? framesPerSecond : 24
        return VideoFrameTimes(times: (0..<max(frameCount, 0)).map { Double($0) / rate })
    }
}
