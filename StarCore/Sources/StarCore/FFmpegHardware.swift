import Foundation

/// How star asks ffmpeg to use the machine's video hardware.
///
/// **Encoding** is the user's explicit choice.  The hardware encoders ffmpeg was built with
/// (`h264_videotoolbox`, `hevc_nvenc`, `h264_amf`, ...) are listed beside the software ones in
/// the Render Video dialog and work like any other encoder.
///
/// **Decoding** is not hardware accelerated unless asked for, because it is not the same decode.
/// Measured on an Apple silicon Mac, VideoToolbox decoding of 8-bit H.264, ProRes and VP9
/// differs from ffmpeg's software decoders by up to a sixth of full scale, including in streams
/// tagged BT.709 limited range; HEVC came out identical.  star turns the decoded frames into
/// TIFFs, processes them, and re-encodes with the software colour conversion, so a quietly
/// different decode is a quietly different colour in the finished video.  Each platform's
/// accelerator (NVDEC, VAAPI, D3D11VA, QSV) converts in its own way too, so "identical for the
/// codecs tried on one machine" is not a basis for turning it on by default.
public enum FFmpegHardware {

    /// Set to an ffmpeg `-hwaccel` method (`auto`, `videotoolbox`, `cuda`, `vaapi`, `d3d11va`,
    /// ...) to decode with that hardware.  Unset, empty, or `0`/`no`/`off`/`none`/`false` is
    /// software decoding, which is the default.
    public static let decodeVariable = "STAR_FFMPEG_HWACCEL"

    /// The ffmpeg options, to go before `-i`, that choose how the input is decoded.
    public static func decodeArguments(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> [String]
    {
        guard let raw = environment[decodeVariable] else { return [] }
        let method = raw.trimmingCharacters(in: .whitespaces)
        switch method.lowercased() {
        case "", "0", "no", "off", "none", "false":
            return []
        default:
            return ["-hwaccel", method]
        }
    }
}

public extension FFmpegEncoder {

    /// Options an encoder needs after `-c:v` and `-pix_fmt` for output worth keeping, because its
    /// own default is not.  The Render Video dialog has no quality control, so for most encoders
    /// whatever ffmpeg defaults to is what a user gets; this is for the ones where that is poor.
    ///
    ///  - NVENC: ffmpeg's default is a 2 Mbit/s target, which is blocky mush for a 4K timelapse.
    ///    `-rc vbr -cq N -b:v 0` is NVIDIA's own recipe for constant quality (N is 0 to 51, lower
    ///    is better): 19 for H.264 and HEVC, which is high quality, and 24 for AV1, which gets
    ///    there with a coarser setting.  Not run here (a Mac has no NVENC); the option names are
    ///    the ones in FFmpeg's nvenc encoders.
    ///  - VideoToolbox: fine as it is.  Measured on 48 frames of a 4K sequence, its default made
    ///    a larger and better file than libx264's default (47.0 dB against 44.5 dB PSNR).
    ///  - AMF: with no rate control given it chooses its own (peak-constrained VBR at the
    ///    encoder's default bitrate), so it is left alone.
    ///
    /// Software encoders have a quality default (CRF) that suits.
    var defaultQualityArguments: [String] {
        switch self {
        case .h264_nvenc, .hevc_nvenc:
            return ["-rc", "vbr", "-cq", "19", "-b:v", "0"]
        case .av1_nvenc:
            return ["-rc", "vbr", "-cq", "24", "-b:v", "0"]
        default:
            return []
        }
    }
}
