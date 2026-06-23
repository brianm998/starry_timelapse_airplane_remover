package com.star.desktop.ui.sequence.edit

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue

/**
 * The painted reference-horizon line, one Y per image column (`-1` = unpainted / all-sky), in image
 * space. A [version] counter bumps on every edit so the Canvas recomposes without an observable
 * per-element list. Snapshot is sent to the daemon as `HorizonColumns` (image-space).
 */
class HorizonPaintState(val imageWidth: Int, val imageHeight: Int) {
    private val ys = IntArray(imageWidth) { -1 }

    /** Bump to force redraw; read it in the Canvas before drawing. */
    var version by mutableStateOf(0)
        private set

    var brushRadius by mutableStateOf((imageWidth / 40).coerceAtLeast(8)) // image px

    private var lastX: Int? = null
    private var lastY: Int? = null

    fun yAt(x: Int): Int = if (x in 0 until imageWidth) ys[x] else -1

    /** Paint the horizon at image (x,y): set a brush-wide span, interpolating from the last sample. */
    fun paint(x: Int, y: Int) {
        val cy = y.coerceIn(0, imageHeight - 1)
        val lx = lastX
        val ly = lastY
        if (lx != null && ly != null && lx != x) {
            // interpolate the boundary between the previous sample and this one
            val lo = minOf(lx, x)
            val hi = maxOf(lx, x)
            for (px in lo..hi) {
                val t = if (hi == lo) 0.0 else (px - lx).toDouble() / (x - lx)
                stamp(px, (ly + (cy - ly) * t).toInt())
            }
        } else {
            stamp(x, cy)
        }
        lastX = x; lastY = cy
        version++
    }

    private fun stamp(centerX: Int, y: Int) {
        val r = brushRadius
        for (px in (centerX - r)..(centerX + r)) {
            if (px in 0 until imageWidth) ys[px] = y
        }
    }

    fun endStroke() { lastX = null; lastY = null }

    fun clear() {
        for (i in ys.indices) ys[i] = -1
        endStroke()
        version++
    }

    /** Seed from an existing reference line (image-space, -1 = unpainted). */
    fun seed(line: List<Int>) {
        for (i in 0 until minOf(line.size, imageWidth)) ys[i] = line[i]
        endStroke()
        version++
    }

    fun snapshot(): List<Int> = ys.toList()
    fun hasAnyPaint(): Boolean = ys.any { it >= 0 }
}
