package com.star.desktop.domain

import com.star.proto.FrameFormat
import com.star.proto.ProbeVideoResponse

/** How the frames of an imported video are written: what `Session.OpenVideo` takes as `frame_format` and `jpeg_quality`. */
enum class FrameFormatChoice(val proto: FrameFormat, val labelKey: String) {
    TIFF16(FrameFormat.FRAME_FORMAT_TIFF16, "ui.frame_format_tiff16"),
    TIFF8(FrameFormat.FRAME_FORMAT_TIFF8, "ui.frame_format_tiff8"),
    JPEG(FrameFormat.FRAME_FORMAT_JPEG, "ui.frame_format_jpeg"),
}

object VideoImport {
    const val DEFAULT_JPEG_QUALITY = 80
    const val MIN_JPEG_QUALITY = 1
    const val MAX_JPEG_QUALITY = 100

    /**
     * Roughly how much disk the frames of the probed video take in this format, or null when the video could not be read or does not say how long it is
     * (the daemon sends 0 for a frame count it does not know).
     */
    fun estimatedBytes(probe: ProbeVideoResponse, format: FrameFormatChoice, jpegQuality: Int): Long? {
        if (!probe.known || probe.width <= 0 || probe.height <= 0 || probe.frameCount <= 0) return null
        val perPixel = when (format) {
            FrameFormatChoice.TIFF16 -> probe.tiff16BytesPerPixel
            FrameFormatChoice.TIFF8 -> probe.tiff8BytesPerPixel
            FrameFormatChoice.JPEG -> {
                val table = probe.jpegBytesPerPixelList
                if (table.isEmpty()) return null
                table[(jpegQuality.coerceIn(MIN_JPEG_QUALITY, MAX_JPEG_QUALITY) - 1).coerceAtMost(table.size - 1)]
            }
        }
        return Math.round(probe.width.toDouble() * probe.height * probe.frameCount * perPixel)
    }

    /** "1.4 GB": decimal units, as the file manager of the platforms star runs on shows sizes. */
    fun formatBytes(bytes: Long): String {
        val units = listOf("bytes", "KB", "MB", "GB", "TB")
        var value = bytes.toDouble()
        var unit = 0
        while (value >= 1000 && unit < units.size - 1) { value /= 1000; unit++ }
        return if (unit == 0) "$bytes ${units[0]}" else "%.1f %s".format(java.util.Locale.ROOT, value, units[unit])
    }
}
