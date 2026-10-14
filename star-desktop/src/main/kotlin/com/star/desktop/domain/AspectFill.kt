package com.star.desktop.domain

/**
 * Which part of a picture shows when it is made to fill a box without being stretched: the picture is scaled until it covers the box, and the
 * overhang is cut off equally on both sides (macOS `resizeAspectFill`, how the start screen's video fills the window).
 */
object AspectFill {
    /** A rectangle of the picture, in its own pixels. */
    data class Source(val x: Int, val y: Int, val width: Int, val height: Int)

    /** The part of a [srcWidth] × [srcHeight] picture that fills a [dstWidth] × [dstHeight] box; all of it when the shapes agree or there is nothing to fit. */
    fun source(srcWidth: Int, srcHeight: Int, dstWidth: Int, dstHeight: Int): Source {
        if (srcWidth <= 0 || srcHeight <= 0 || dstWidth <= 0 || dstHeight <= 0) return Source(0, 0, maxOf(srcWidth, 0), maxOf(srcHeight, 0))
        // Compared by cross-multiplying, so that equal shapes are exactly equal and not merely close.
        val srcWider = srcWidth.toLong() * dstHeight > dstWidth.toLong() * srcHeight
        return if (srcWider) {
            // too wide: the sides are cut, the full height shows
            val width = (srcHeight.toLong() * dstWidth / dstHeight).toInt().coerceIn(1, srcWidth)
            Source((srcWidth - width) / 2, 0, width, srcHeight)
        } else {
            // too tall (or the same shape): the top and bottom are cut, the full width shows
            val height = (srcWidth.toLong() * dstHeight / dstWidth).toInt().coerceIn(1, srcHeight)
            Source(0, (srcHeight - height) / 2, srcWidth, height)
        }
    }
}
