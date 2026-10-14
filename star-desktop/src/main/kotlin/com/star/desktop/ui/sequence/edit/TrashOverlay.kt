package com.star.desktop.ui.sequence.edit

import androidx.compose.ui.graphics.ImageBitmap
import com.star.desktop.data.OutlierRepository

/** The frame's trashed outlier pixels, drawn in yellow under the groups (macOS `trashImage`, template-coloured yellow at `trashOpacity`). */
object TrashOverlay {
    private const val YELLOW = 0xFFFFCC00.toInt()

    /** The overlay's pixels for [mask], at most [OutlierOverlay.MAX_WIDTH] wide, with [opacity] (0..1) as their alpha. */
    fun pixels(mask: OutlierRepository.Mask, opacity: Float): OutlierOverlay.Pixels {
        val scale = minOf(1.0, OutlierOverlay.MAX_WIDTH.toDouble() / mask.width)
        val ow = maxOf(1, (mask.width * scale).toInt())
        val oh = maxOf(1, (mask.height * scale).toInt())
        val alpha = (opacity.coerceIn(0f, 1f) * 255).toInt()
        val argb = (alpha shl 24) or (YELLOW and 0xFFFFFF)
        val out = IntArray(ow * oh)
        for (y in 0 until mask.height) {
            val oy = minOf(oh - 1, (y * scale).toInt())
            val row = y * mask.width
            for (x in 0 until mask.width) {
                if (mask.set[row + x].toInt() != 0) out[oy * ow + minOf(ow - 1, (x * scale).toInt())] = argb
            }
        }
        return OutlierOverlay.Pixels(ow, oh, out)
    }

    fun bitmap(mask: OutlierRepository.Mask, opacity: Float): ImageBitmap = pixels(mask, opacity).toImageBitmap()
}
