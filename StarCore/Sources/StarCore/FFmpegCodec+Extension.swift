import Foundation

public extension FFmpegCodec {

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
}

public extension FFmpegEncoder {
    public var supportedMuxers: [FFmpegMuxer] {
        var ret: [FFmpegMuxer] = []
        for muxer in FFmpegMuxer.allCases {
            if muxer.supportedEncoders.contains(self) { ret.append(muxer) }
        }
        return ret
    }
}
