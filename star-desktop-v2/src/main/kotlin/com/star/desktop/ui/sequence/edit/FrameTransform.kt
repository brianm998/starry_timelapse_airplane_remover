package com.star.desktop.ui.sequence.edit

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import kotlin.math.min

/**
 * The single source-of-truth transform between **image space** (full-resolution pixel coordinates,
 * top-left origin — the space outlier bounding boxes and the label image live in) and **canvas
 * space** (on-screen pixels). The frame image, the outlier overlay, and click hit-testing all use
 * this one transform, so they can never disagree (the v1 client had three separate, drifting
 * coordinate bases — its overlay was broken off zoom=1).
 */
class FrameTransform(val imageWidth: Int, val imageHeight: Int) {
    var userZoom by mutableStateOf(1f)
        private set
    var pan by mutableStateOf(Offset.Zero)

    /** Fit-to-canvas base scale (whole image visible at zoom 1). */
    fun baseScale(canvas: Size): Float =
        if (imageWidth <= 0 || imageHeight <= 0 || canvas.width <= 0f) 1f
        else min(canvas.width / imageWidth, canvas.height / imageHeight)

    fun scale(canvas: Size): Float = baseScale(canvas) * userZoom

    /** Top-left of the drawn image in canvas space (centered, plus pan). */
    fun origin(canvas: Size): Offset {
        val s = scale(canvas)
        val drawW = imageWidth * s
        val drawH = imageHeight * s
        return Offset((canvas.width - drawW) / 2f + pan.x, (canvas.height - drawH) / 2f + pan.y)
    }

    fun imageToCanvas(p: Offset, canvas: Size): Offset {
        val s = scale(canvas)
        val o = origin(canvas)
        return Offset(o.x + p.x * s, o.y + p.y * s)
    }

    fun canvasToImage(p: Offset, canvas: Size): Offset {
        val s = scale(canvas).coerceAtLeast(1e-6f)
        val o = origin(canvas)
        return Offset((p.x - o.x) / s, (p.y - o.y) / s)
    }

    /** Zoom by [factor] keeping the image point under [focus] (canvas space) stationary. */
    fun zoomBy(factor: Float, focus: Offset, canvas: Size) {
        val imgPt = canvasToImage(focus, canvas)
        userZoom = (userZoom * factor).coerceIn(MIN_ZOOM, MAX_ZOOM)
        val after = imageToCanvas(imgPt, canvas)
        pan += (focus - after)
    }

    fun panBy(delta: Offset) { pan += delta }

    fun reset() {
        userZoom = 1f
        pan = Offset.Zero
    }

    companion object {
        const val MIN_ZOOM = 0.1f
        const val MAX_ZOOM = 10f
    }
}
