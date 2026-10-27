package com.star.desktop.domain

import com.star.proto.FrameFormat
import com.star.proto.ProbeVideoResponse

/** How the frames of an imported video are written: what `Session.OpenVideo` takes as `frame_format` and `jpeg_quality`. */
enum class FrameFormatChoice(val proto: FrameFormat, val labelKey: String) {
    TIFF16(FrameFormat.FRAME_FORMAT_TIFF16, "ui.frame_format_tiff16"),
    TIFF8(FrameFormat.FRAME_FORMAT_TIFF8, "ui.frame_format_tiff8"),
    JPEG(FrameFormat.FRAME_FORMAT_JPEG, "ui.frame_format_jpeg"),
}

/** How tiff frames are compressed: what `Session.OpenVideo` takes as `tiff_compression`. Both are lossless and give the same pictures. */
enum class TiffCompressionChoice(val proto: com.star.proto.TiffCompression, val labelKey: String) {
    /** Read about twice as fast while star processes the frames, for roughly 10% more disk. */
    NONE(com.star.proto.TiffCompression.TIFF_COMPRESSION_NONE, "ui.tiff_compression_none"),
    /** What every import before the choice existed wrote. */
    PACKBITS(com.star.proto.TiffCompression.TIFF_COMPRESSION_PACKBITS, "ui.tiff_compression_packbits"),
}

/** What the import dialog answers. */
data class VideoImportOptions(
    val format: FrameFormatChoice = FrameFormatChoice.TIFF16,
    val jpegQuality: Int = VideoImport.DEFAULT_JPEG_QUALITY,
    val tiffCompression: TiffCompressionChoice = TiffCompressionChoice.PACKBITS,
    /** Go to the main screen while the video's frames are still being extracted. */
    val extractInBackground: Boolean = false,
)

object VideoImport {
    const val DEFAULT_JPEG_QUALITY = 80
    const val MIN_JPEG_QUALITY = 1
    const val MAX_JPEG_QUALITY = 100

    /**
     * Roughly how much disk the frames of the probed video take in this format, or null when the video could not be read or does not say how long it is
     * (the daemon sends 0 for a frame count it does not know).
     */
    fun estimatedBytes(
        probe: ProbeVideoResponse, format: FrameFormatChoice, jpegQuality: Int,
        tiffCompression: TiffCompressionChoice = TiffCompressionChoice.PACKBITS,
    ): Long? {
        if (!probe.known || probe.width <= 0 || probe.height <= 0 || probe.frameCount <= 0) return null
        val raw = tiffCompression == TiffCompressionChoice.NONE
        val perPixel = when (format) {
            FrameFormatChoice.TIFF16 -> if (raw && probe.tiff16RawBytesPerPixel > 0) probe.tiff16RawBytesPerPixel else probe.tiff16BytesPerPixel
            FrameFormatChoice.TIFF8 -> if (raw && probe.tiff8RawBytesPerPixel > 0) probe.tiff8RawBytesPerPixel else probe.tiff8BytesPerPixel
            FrameFormatChoice.JPEG -> {
                val table = probe.jpegBytesPerPixelList
                if (table.isEmpty()) return null
                table[(jpegQuality.coerceIn(MIN_JPEG_QUALITY, MAX_JPEG_QUALITY) - 1).coerceAtMost(table.size - 1)]
            }
        }
        return Math.round(probe.width.toDouble() * probe.height * probe.frameCount * perPixel)
    }

    /**
     * Whether "extract in background" starts on: for a video that gives up any frame cheaply (every frame a keyframe: ProRes, DNxHD, intra
     * H.264...), not for H.264, H.265 and the like, where a frame costs a second or two to reach and processing has to wait in order.
     */
    fun extractInBackgroundByDefault(probe: ProbeVideoResponse?): Boolean = probe != null && probe.known && probe.seekable

    /** "1.4 GB": decimal units, as the file manager of the platforms star runs on shows sizes. */
    fun formatBytes(bytes: Long): String {
        val units = listOf("bytes", "KB", "MB", "GB", "TB")
        var value = bytes.toDouble()
        var unit = 0
        while (value >= 1000 && unit < units.size - 1) { value /= 1000; unit++ }
        return if (unit == 0) "$bytes ${units[0]}" else "%.1f %s".format(java.util.Locale.ROOT, value, units[unit])
    }
}
