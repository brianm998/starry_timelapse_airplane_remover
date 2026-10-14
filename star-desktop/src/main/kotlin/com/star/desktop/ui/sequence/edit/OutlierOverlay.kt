package com.star.desktop.ui.sequence.edit

import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.toComposeImageBitmap
import com.star.desktop.data.OutlierRepository
import com.star.desktop.domain.OutlierDecisions
import com.star.proto.OutlierGroup
import com.star.proto.RemoveReason
import java.awt.image.BufferedImage

/**
 * The outlier groups drawn as pixels (macOS shows each group's own pixels tinted by its decision rather than a box around it).
 * Built from the 16-bit label map the daemon provides, so what is tinted is exactly what a click can hit, and rebuilt when a
 * decision or the selection changes.
 */
object OutlierOverlay {
    /** Groups of this many pixels or fewer are not separate things in the UI: they are drawn in two combined masks and cannot be clicked (macOS `size > 40`). */
    const val SMALL_GROUP_PIXELS = 40

    /** The overlay is at most this wide: a 42 MP frame's overlay at full resolution would be 170 MB for something drawn at screen size. */
    const val MAX_WIDTH = 2048

    // ARGB. The group colours of macOS (`OutlierGroupViewModel.groupColor`) at the strength the hard-light blend gives them, approximated by alpha.
    private const val RED = 0xFFFF3B30.toInt()
    private const val GREEN = 0xFF34C759.toInt()
    private const val BLUE = 0xFF0A84FF.toInt()
    private const val ORANGE = 0xFFFF9500.toInt()

    private fun withAlpha(argb: Int, alpha: Int) = (alpha shl 24) or (argb and 0xFFFFFF)

    /** Whether the group is a separate thing in the UI (drawn with its own colour, hoverable, clickable). */
    fun isLarge(group: OutlierGroup): Boolean = group.size > SMALL_GROUP_PIXELS

    /** The colour (ARGB) the group is drawn in. */
    fun colorOf(group: OutlierGroup, reason: RemoveReason, selected: Boolean): Int {
        val willRemove = OutlierDecisions.willRemove(reason)
        return if (isLarge(group)) {
            when {
                selected -> withAlpha(ORANGE, 0x99)
                willRemove == true -> withAlpha(RED, 0x99)
                willRemove == false -> withAlpha(GREEN, 0x99)
                else -> withAlpha(BLUE, 0x99)
            }
        } else {
            // Small groups: two combined masks, red for what will be painted out and green for the rest (undecided included).
            withAlpha(if (willRemove == true) RED else GREEN, 0xCC)
        }
    }

    /**
     * The overlay's pixels (ARGB, row-major, `width` x `height`), and its size, for a frame of [imageWidth] x [imageHeight]:
     * each group's pixels, found in [labels] inside the group's own bounding box, in the colour [colorOf] gives it. Pixels of no
     * group stay transparent. Only the groups' boxes are scanned, not the whole frame.
     */
    fun pixels(
        labels: OutlierRepository.LabelMap,
        groups: List<OutlierGroup>,
        decisions: Map<Int, RemoveReason>,
        selected: Set<Int>,
    ): Pixels {
        val scale = minOf(1.0, MAX_WIDTH.toDouble() / labels.width)
        val ow = maxOf(1, (labels.width * scale).toInt())
        val oh = maxOf(1, (labels.height * scale).toInt())
        val out = IntArray(ow * oh)
        // Small groups first, so a large group that overlaps one is not hidden by it.
        for (group in groups.sortedBy { isLarge(it) }) {
            val reason = decisions[group.id] ?: group.shouldRemove
            val argb = colorOf(group, reason, group.id in selected)
            val b = group.bounds
            val y0 = b.minY.coerceAtLeast(0)
            val y1 = b.maxY.coerceAtMost(labels.height - 1)
            val x0 = b.minX.coerceAtLeast(0)
            val x1 = b.maxX.coerceAtMost(labels.width - 1)
            for (y in y0..y1) {
                val oy = minOf(oh - 1, (y * scale).toInt())
                for (x in x0..x1) {
                    if (labels.idAt(x, y) == group.id) out[oy * ow + minOf(ow - 1, (x * scale).toInt())] = argb
                }
            }
        }
        return Pixels(ow, oh, out)
    }

    class Pixels(val width: Int, val height: Int, val argb: IntArray) {
        fun toImageBitmap(): ImageBitmap {
            val image = BufferedImage(width, height, BufferedImage.TYPE_INT_ARGB)
            image.setRGB(0, 0, width, height, argb, 0, width)
            return image.toComposeImageBitmap()
        }
    }
}
