import Foundation

public extension FFmpegCodec {

    static var availableVideoCodecs: [FFmpegCodec] {

        let start: [FFmpegCodec] = [
          .h264,
          .hevc,
          .mpeg4,
          .prores,
          .dnxhd,
          .av1,
          .rawvideo,
          .gif
        ]

        let all = start + self.allCases
          .filter { !start.contains($0) }

        return all
          .filter { $0.canDecode }
          .filter { $0.canEncode }
          .filter { $0.pixelFormatCount > 0 }
          .filter { $0.type == .video }
    }

    func encoder(for pixelFormat: FFmpegPixelFormat) -> FFmpegEncoder? {
        for encoder in self.encoders {
            for format in encoder.pixelFormats {
                if format == pixelFormat { return encoder }
            }
        }
        return nil
    }
    
    var pixelFormatCount: Int {
        self.encoders.map { $0.pixelFormats.count }.reduce(0, +)
    }
    
    // online guesses :(
    var supportedMuxers: [FFmpegMuxer] {
        switch self {
        case .h264:
            return [.mp4, .mov, .avi]
        case .hevc:
            return [.mp4, .mov]
        case .mpeg4:
            return [.avi, .mp4, .mov]
        case .vp8:
            return [.webm]
        case .vp9:
            return [.webm]
        case .av1:
            return [.webm]
        case .prores:
            return [.mov]
        case .dnxhd:
            return [.mov]
        case .cfhd:
            return [.mov]
        case .ffv1:
            return [.avi]
        case .huffyuv, .loco, .utvideo:
            return [.avi]
        case .rawvideo:
            return [.avi, .mov]
        case .gif:
            return [.gif]
        default:
            return [.mov] // safe fallback?
        }
    }
}
