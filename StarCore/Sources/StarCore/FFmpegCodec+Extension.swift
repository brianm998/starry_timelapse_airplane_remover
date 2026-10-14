import Foundation

public extension FFmpegCodec {

    /// The codecs the Render Video dialog offers: the four star leads with, then the rest by
    /// name; each one that this ffmpeg can encode (see `availableEncoders`) and that is video.
    static var availableVideoCodecs: [FFmpegCodec] {

        // stick these at the top
        let start: [FFmpegCodec] = [
          .h264,
          .hevc,
          .prores,
          .dnxhd,
        ]

        let all = start + self.allCases
          .filter { !start.contains($0) }
          .sorted { $0.description.lowercased() < $1.description.lowercased() }

        return all
          .filter { $0.canDecode }
          .filter { $0.canEncode }
          .filter { $0.type == .video }
          .filter { !$0.availableEncoders.isEmpty }
    }

    /// The encoders of this codec a user can pick: this ffmpeg has them, a hardware one starts
    /// on this machine, there is a pixel format star can hand them, and some container can hold
    /// what they write.  Software encoders come first, so the dialog opens on the one that is
    /// the same everywhere.
    var availableEncoders: [FFmpegEncoder] {
        let usable = encoders.filter {
            $0.hasAContainer && !$0.usablePixelFormats.isEmpty && $0.isAvailable
        }
        return usable.filter { !$0.isHardware } + usable.filter { $0.isHardware }
    }

    /// The encoder to re-encode this codec with when the pixel format is `pixelFormat`: the first
    /// available one that takes it, which is a software encoder if there is one.
    func encoder(for pixelFormat: FFmpegPixelFormat) -> FFmpegEncoder? {
        availableEncoders.first { $0.usablePixelFormats.contains(pixelFormat) }
    }
    
    var pixelFormatCount: Int {
        self.encoders.map { $0.pixelFormats.count }.reduce(0, +)
    }

    /// The container this codec belongs in, among the ones `encoder` can write: what people
    /// expect of the format, rather than whichever happens to come first in a list of nearly
    /// two hundred.
    func defaultMuxer(for encoder: FFmpegEncoder) -> FFmpegMuxer? {
        let muxers = encoder.supportedMuxers
        let preferences: [FFmpegMuxer]
        switch self {
        case .h264, .hevc, .av1:    preferences = [.mp4, .mov, .matroska]
        case .vp8, .vp9:            preferences = [.webm, .matroska]
        default:                    preferences = [.mov, .mp4, .matroska, .avi]
        }
        return preferences.first { muxers.contains($0) } ?? muxers.first
    }

    /// A set of video settings that go together, made from whatever was asked for: each part is
    /// kept if it fits the parts before it and otherwise replaced by one that does.  What comes
    /// back is always something the Render Video dialog can show, since it reads the first
    /// entry of each list.  nil only if there is no codec to offer at all.
    static func consistentSettings(codec: FFmpegCodec,
                                   encoder: FFmpegEncoder,
                                   pixelFormat: FFmpegPixelFormat,
                                   muxer: FFmpegMuxer)
      -> (codec: FFmpegCodec, encoder: FFmpegEncoder, pixelFormat: FFmpegPixelFormat, muxer: FFmpegMuxer)?
    {
        let codecs = availableVideoCodecs
        guard let firstCodec = codecs.first else { return nil }

        let chosenCodec = codecs.contains(codec) ? codec : firstCodec
        let encoders = chosenCodec.availableEncoders
        let chosenEncoder = encoders.contains(encoder) ? encoder : encoders[0]
        let pixelFormats = chosenEncoder.usablePixelFormats
        let chosenPixelFormat = pixelFormats.contains(pixelFormat) ? pixelFormat : pixelFormats[0]
        let muxers = chosenEncoder.supportedMuxers
        let chosenMuxer = muxers.contains(muxer)
          ? muxer
          : chosenCodec.defaultMuxer(for: chosenEncoder) ?? muxers[0]

        return (chosenCodec, chosenEncoder, chosenPixelFormat, chosenMuxer)
    }
}

public extension FFmpegEncoder {
    var supportedMuxers: [FFmpegMuxer] {
        var ret: [FFmpegMuxer] = []
        for muxer in FFmpegMuxer.allCases {
            if muxer.supportedEncoders.contains(self) { ret.append(muxer) }
        }
        return ret
    }

    /// Whether any container takes what this encoder writes.  A few, like the Radiance HDR image
    /// encoder, are in the tables but fit no container, so the dialog would have nowhere to
    /// put what they make (and indexes the container list's first entry).
    var hasAContainer: Bool {
        FFmpegEncoder.encodersWithAContainer.contains(self)
    }

    /// Every encoder some container lists, worked out once.
    private static let encodersWithAContainer: Set<FFmpegEncoder> = {
        var encoders: Set<FFmpegEncoder> = []
        for muxer in FFmpegMuxer.allCases {
            encoders.formUnion(muxer.supportedEncoders)
        }
        return encoders
    }()

    /// True for the encoders that run on a GPU or media engine rather than the CPU.  They are
    /// named for the API they use, and are the ones whose presence in ffmpeg does not mean the
    /// hardware is.
    var isHardware: Bool {
        FFmpegEncoder.hardwareSuffixes.contains { rawValue.hasSuffix($0) }
    }

    private static let hardwareSuffixes = [
        "_videotoolbox", "_nvenc", "_amf", "_qsv", "_vaapi", "_vulkan", "_mf", "_v4l2m2m",
        "_omx", "_mediacodec", "_rkmpp", "_d3d12va",
    ]

    /// The pixel formats the dialog can offer for this encoder: the ones in its table entry that
    /// are real pixel layouts ffmpeg can convert star's frames to.  The table also lists the
    /// encoder's GPU surface formats (`videotoolbox_vld`, `cuda`, `d3d11`, ...), which come first
    /// for the VideoToolbox encoders and which no still-image input can be: choosing one fails
    /// the export, and as the first entry it would have been the default.
    var usablePixelFormats: [FFmpegPixelFormat] {
        pixelFormats.filter {
            !$0.isHardwareAccelrated && !$0.isBitstream && !$0.isPalleted && $0.canOutput
        }
    }

    /// Whether this ffmpeg has the encoder and, if it is a hardware one, this machine can run it.
    var isAvailable: Bool {
        FFmpegCapabilities.shared.isUsable(self)
    }
}
