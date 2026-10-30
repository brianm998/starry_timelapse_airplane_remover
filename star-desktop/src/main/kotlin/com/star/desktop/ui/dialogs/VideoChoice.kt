package com.star.desktop.ui.dialogs

import com.star.proto.SessionInfo
import com.star.proto.VideoCapabilities
import com.star.proto.VideoEncodeSettings

/**
 * What the Render Video dialog's pickers are set to. The pickers cascade (a codec has encoders, an encoder has
 * pixel formats and containers), so a choice is only ever built by these functions, which keep every level a
 * value the level above allows.
 */
data class VideoChoice(
    val codec: String,
    val encoder: String,
    val pixelFormat: String,
    val muxer: String,
    val frameRate: Double,
    /** Height in pixels the video is scaled to, 0 for as the frames are. */
    val outputHeight: Int = 0,
) {
    /** The codec [codec], with the rest re-validated under it: each kept if the new codec still offers it, else the first it does. */
    fun withCodec(caps: VideoCapabilities, codec: String): VideoChoice =
        resolveVideoChoice(caps, VideoEncodeSettings.newBuilder()
            .setCodec(codec).setEncoder(encoder).setPixelFormat(pixelFormat).setMuxer(muxer).setFrameRate(frameRate).setOutputHeight(outputHeight).build())

    /** The encoder [encoder] of this codec, with its pixel format and container kept if it offers them. */
    fun withEncoder(caps: VideoCapabilities, encoder: String): VideoChoice =
        resolveVideoChoice(caps, VideoEncodeSettings.newBuilder()
            .setCodec(codec).setEncoder(encoder).setPixelFormat(pixelFormat).setMuxer(muxer).setFrameRate(frameRate).setOutputHeight(outputHeight).build())

    fun toSettings(): VideoEncodeSettings = VideoEncodeSettings.newBuilder()
        .setFrameRate(frameRate).setCodec(codec).setEncoder(encoder).setPixelFormat(pixelFormat).setMuxer(muxer).setOutputHeight(outputHeight).build()
}

/**
 * The choice to start from: [wanted] where the capabilities allow it, walking down the chain codec → encoder →
 * pixel format and container, and the first valid entry wherever it does not (or where [wanted] has nothing).
 * A frame rate is kept whatever it is, as long as it is positive: 29.97 from an imported video is not in the list
 * of the standard rates, and is still the right one for it.
 */
fun resolveVideoChoice(caps: VideoCapabilities, wanted: VideoEncodeSettings?): VideoChoice {
    val codecs = caps.codecsList
    val codecCaps = codecs.firstOrNull { it.codec == wanted?.codec } ?: codecs.firstOrNull()
    val encoders = codecCaps?.encodersList.orEmpty()
    val encoderCaps = encoders.firstOrNull { it.encoder == wanted?.encoder } ?: encoders.firstOrNull()
    val pixelFormats = encoderCaps?.pixelFormatsList.orEmpty()
    val muxers = encoderCaps?.muxersList.orEmpty()
    return VideoChoice(
        codec = codecCaps?.codec.orEmpty(),
        encoder = encoderCaps?.encoder.orEmpty(),
        pixelFormat = pixelFormats.firstOrNull { it == wanted?.pixelFormat } ?: pixelFormats.firstOrNull().orEmpty(),
        muxer = muxers.firstOrNull { it == wanted?.muxer } ?: muxers.firstOrNull().orEmpty(),
        frameRate = wanted?.frameRate?.takeIf { it > 0 } ?: caps.frameRatesList.firstOrNull() ?: DEFAULT_FRAME_RATE,
        outputHeight = wanted?.outputHeight ?: 0,
    )
}

/**
 * What a render starts from: the encode settings the session's config holds, as the macOS gui reads them and nothing else (L12). A video import
 * has put its own there (a 29.97 fps import is rendered at 29.97 and not at the list's first rate: `Config.set(videoInfo:)` when the
 * daemon opens the video), and a reopened session has what it was saved with. null when the config names no codec, which is a sequence that
 * never had a video. What the user last chose in this dialog used to be laid over it, and the source video's own settings under it, so the
 * two clients started from different places.
 */
fun storedVideoSettings(info: SessionInfo?): VideoEncodeSettings? {
    if (info == null) return null
    if (info.config.hasVideo() && info.config.video.codec.isNotEmpty()) return info.config.video
    return null
}

private const val DEFAULT_FRAME_RATE = 24.0
