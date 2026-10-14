import Foundation

/// What the frames of an imported video are written as.
///
/// A video comes in as one image file per frame (see `decodeVideo`).  16 bit tiff is the default: it
/// is lossless and holds everything the decoder produces, but a frame of it is 6 bytes a pixel.
/// 8 bit tiff halves that, and jpeg takes a small fraction of it for a loss of quality that is
/// chosen with `jpegQuality`.
public struct FrameDecodeFormat: Sendable, Equatable, Codable {

    public enum Kind: String, Sendable, Codable, CaseIterable {
        case tiff16
        case tiff8
        case jpeg

        /// The extension the decoded frames get.
        public var fileExtension: String { self == .jpeg ? "jpg" : "tiff" }
    }

    public static let defaultJPEGQuality = 80
    public static let jpegQualityRange = 1...100

    public var kind: Kind
    /// 1 (smallest) ... 100 (best).  Only jpeg looks at it.
    public var jpegQuality: Int

    public init(kind: Kind = .tiff16, jpegQuality: Int = FrameDecodeFormat.defaultJPEGQuality) {
        self.kind = kind
        self.jpegQuality = min(max(jpegQuality, Self.jpegQualityRange.lowerBound), Self.jpegQualityRange.upperBound)
    }

    /// 16 bit tiff, what star has always written.
    public static let tiff16 = FrameDecodeFormat(kind: .tiff16)
    public static let tiff8 = FrameDecodeFormat(kind: .tiff8)
    /// jpeg at the default quality.
    public static let jpeg = FrameDecodeFormat(kind: .jpeg)

    public var fileExtension: String { kind.fileExtension }

    /// ffmpeg's name for the quality: its jpeg encoder takes `-q:v` from 2 (best) to 31 (worst).
    var ffmpegQualityScale: Int {
        let fraction = Double(jpegQuality) / 100
        return Int((31 - fraction * 29).rounded())
    }

    /// The ffmpeg arguments that turn the decoded video into this format, ending in the output pattern
    /// inside `folder`, and not including the input.
    func ffmpegOutputArguments(in folder: String) -> [String] {
        let pattern = "\(folder)/image_%04d.\(fileExtension)"
        switch kind {
        case .tiff16: return ["-pix_fmt", "rgb48le", pattern]
        case .tiff8:  return ["-pix_fmt", "rgb24", pattern]
        // yuvj444p: full range, and chroma is not subsampled, which would smear the colour of a star.
        case .jpeg:   return ["-pix_fmt", "yuvj444p", "-q:v", "\(ffmpegQualityScale)", pattern]
        }
    }

    // MARK: disk usage

    /// Roughly how many bytes one pixel of a frame takes on disk.
    ///
    /// The tiffs are exact (ffmpeg's tiff encoder hardly compresses a noisy sky, measured 3.03 and 5.9
    /// bytes a pixel).  Jpeg depends on what is in the frame, so this is a measurement of night sky
    /// frames at each quality, with half as much again on top so that the estimate errs towards
    /// more space than is needed.
    public var estimatedBytesPerPixel: Double {
        switch kind {
        case .tiff16: return 6.1
        case .tiff8:  return 3.1
        case .jpeg:   return Self.jpegBytesPerPixel(quality: jpegQuality) * 1.5
        }
    }

    /// bytes per pixel measured for ffmpeg jpeg (4:4:4) of 4240x2832 night sky frames, by quality.
    private static let jpegMeasured: [(quality: Double, bytesPerPixel: Double)] = [
        (1, 0.0315), (10, 0.0327), (30, 0.0361), (50, 0.0422), (60, 0.0452), (70, 0.0518),
        (80, 0.0627), (85, 0.0774), (90, 0.0888), (95, 0.1215), (100, 0.1529),
    ]

    static func jpegBytesPerPixel(quality: Int) -> Double {
        let q = Double(quality)
        let table = jpegMeasured
        if q <= table[0].quality { return table[0].bytesPerPixel }
        for (low, high) in zip(table, table.dropFirst()) where q <= high.quality {
            let t = (q - low.quality) / (high.quality - low.quality)
            return low.bytesPerPixel + t * (high.bytesPerPixel - low.bytesPerPixel)
        }
        return table[table.count - 1].bytesPerPixel
    }

    /// The disk space the frames of a video of this size will take, or nil when either is not known.
    public func estimatedBytes(width: Int, height: Int, frameCount: Int) -> Int64? {
        guard width > 0, height > 0, frameCount > 0 else { return nil }
        return Int64((Double(width) * Double(height) * Double(frameCount) * estimatedBytesPerPixel).rounded())
    }
}

/// What can be learned about a video quickly, without decoding it: enough to say how much disk its
/// frames will need.
public struct VideoProbe: Sendable, Equatable {
    public let width: Int
    public let height: Int
    /// The frames in the video, or nil if the file does not say and has no duration to work it out from.
    public let frameCount: Int?

    public init(width: Int, height: Int, frameCount: Int?) {
        self.width = width
        self.height = height
        self.frameCount = frameCount
    }

    /// nil when the size of the video is not known.
    public func estimatedBytes(for format: FrameDecodeFormat) -> Int64? {
        guard let frameCount else { return nil }
        return format.estimatedBytes(width: width, height: height, frameCount: frameCount)
    }

    /// Reads the video's header with ffprobe (no decoding, so it is quick); nil if that fails or
    /// gives no size.
    public static func probe(videoAt path: String) -> VideoProbe? {
        guard let output = try? shellOut(
          to: ToolPaths.ffprobe,
          arguments: [
            "-v", "error", "-select_streams", "v:0",
            "-show_entries", "stream=width,height,nb_frames,duration,r_frame_rate",
            "-of", "default=noprint_wrappers=1",
            path
          ]) else { return nil }
        return parse(ffprobeOutput: output)
    }

    /// Parses `key=value` lines as ffprobe prints them.
    static func parse(ffprobeOutput output: String) -> VideoProbe? {
        var values: [String: String] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 { values[parts[0]] = parts[1].trimmingCharacters(in: .whitespaces) }
        }
        guard let width = values["width"].flatMap({ Int($0) }),
              let height = values["height"].flatMap({ Int($0) }),
              width > 0, height > 0 else { return nil }

        var frames = values["nb_frames"].flatMap { Int($0) }
        if frames == nil || frames == 0 {
            frames = nil
            if let duration = values["duration"].flatMap({ Double($0) }),
               let rateText = values["r_frame_rate"] {
                let parts = rateText.split(separator: "/").compactMap { Double($0) }
                let rate = parts.count == 2 ? (parts[1] != 0 ? parts[0] / parts[1] : 0) : (parts.first ?? 0)
                if rate > 0, duration > 0 { frames = Int((duration * rate).rounded()) }
            }
        }
        return VideoProbe(width: width, height: height, frameCount: frames)
    }
}
