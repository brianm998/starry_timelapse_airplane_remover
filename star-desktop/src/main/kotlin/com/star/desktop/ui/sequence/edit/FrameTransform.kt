package com.star.desktop.ui.sequence.edit

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

/**
 * The single source-of-truth transform between **image space** (full-resolution pixel coordinates,
 * top-left origin — the space outlier bounding boxes and the label image live in) and **canvas
 * space** (on-screen pixels). The frame image, the outlier overlay, the horizon painter and click
 * hit-testing all use this one transform, so they can never disagree (the v1 client had three
 * separate, drifting coordinate bases — its overlay was broken off zoom=1).
 *
 * One instance lives for the whole session (on the sequence view model): the zoom and pan are the user's
 * view of the frames and stay as they are from one frame to the next and between the edit view and the
 * horizon painter, as on macOS.
 *
 * Zoom is expressed two ways. [userZoom] is relative to *fit* (1 = the whole image just fits the canvas, and
 * the view never zooms out past that); the *scale* is the actual size, with 1 meaning one image pixel per screen
 * pixel, which is what the slider and the "Max" field show (macOS `currentZoomScale` / `maxZoomScale`).
 */
class FrameTransform(val imageWidth: Int, val imageHeight: Int) {
    var userZoom by mutableStateOf(1f)
        private set
    var pan by mutableStateOf(Offset.Zero)
        private set

    /** The most the view can zoom in to, as a scale (macOS `maxZoomScale`, default 1 = 100%, at most [MAX_SCALE_LIMIT]). */
    var maxScale by mutableStateOf(1f)
        private set

    /** The size of the view this is drawn in, as last reported; the zoom slider's range depends on it. */
    var canvas by mutableStateOf(Size.Zero)
        private set

    /** Fit-to-canvas base scale (whole image visible at zoom 1). */
    fun baseScale(canvas: Size): Float =
        if (imageWidth <= 0 || imageHeight <= 0 || canvas.width <= 0f || canvas.height <= 0f) 1f
        else min(canvas.width / imageWidth, canvas.height / imageHeight)

    fun scale(canvas: Size): Float = baseScale(canvas) * userZoom

    /** The largest [userZoom] the current [maxScale] allows on [canvas]: never below fit, however small the limit. */
    fun maxUserZoom(canvas: Size): Float = max(1f, maxScale / baseScale(canvas))

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

    /** The view being drawn into changed size: remember it, and keep the image where it can still be reached. */
    fun canvasChanged(size: Size) {
        canvas = size
        userZoom = userZoom.coerceIn(MIN_ZOOM, maxUserZoom(size))
        pan = clampedPan(pan, size)
    }

    /** Zoom by [factor] keeping the image point under [focus] (canvas space) stationary. */
    fun zoomBy(factor: Float, focus: Offset, canvas: Size) {
        val imgPt = canvasToImage(focus, canvas)
        userZoom = (userZoom * factor).coerceIn(MIN_ZOOM, maxUserZoom(canvas))
        val after = imageToCanvas(imgPt, canvas)
        pan = clampedPan(pan + (focus - after), canvas)
    }

    /** Zoom to an absolute [scale] (the slider), about the middle of the view. */
    fun setScale(scale: Float, canvas: Size) {
        val base = baseScale(canvas)
        zoomBy((scale / base) / userZoom, Offset(canvas.width / 2f, canvas.height / 2f), canvas)
    }

    /** Double-click: from fit to 100% (one image pixel per screen pixel, or as close as the limit allows) around [focus], and back. */
    fun toggleFitActual(focus: Offset, canvas: Size) {
        if (userZoom > 1.001f) {
            zoomBy(1f / userZoom, focus, canvas)
        } else {
            val target = (1f / baseScale(canvas)).coerceIn(1f, maxUserZoom(canvas))
            zoomBy(target / userZoom, focus, canvas)
        }
    }

    /** Move the image by [delta] canvas pixels. At fit there is nowhere to move it to; zoomed in it cannot leave the view. */
    fun panBy(delta: Offset, canvas: Size) { pan = clampedPan(pan + delta, canvas) }

    /** Change the largest scale the zoom can reach (the "Max" field); pulls the current zoom back inside it. */
    fun setMaxScale(value: Float, canvas: Size) {
        maxScale = value.coerceIn(MIN_MAX_SCALE, MAX_SCALE_LIMIT)
        userZoom = userZoom.coerceIn(MIN_ZOOM, maxUserZoom(canvas))
        pan = clampedPan(pan, canvas)
    }

    fun reset() {
        userZoom = 1f
        pan = Offset.Zero
    }

    /** [p] limited so that no edge of the image is pulled inside the view's own edge: the picture fills the view or is centered. */
    private fun clampedPan(p: Offset, canvas: Size): Offset {
        val s = scale(canvas)
        fun axis(v: Float, drawn: Float, view: Float): Float {
            val room = max(0f, (drawn - view) / 2f)
            return v.coerceIn(-room, room)
        }
        return Offset(axis(p.x, imageWidth * s, canvas.width), axis(p.y, imageHeight * s, canvas.height))
    }

    companion object {
        /** Fit: the view never zooms out past the whole image (macOS cannot either). */
        const val MIN_ZOOM = 1f

        /** The ceiling for the "Max" field (macOS `EditableMaxZoomView` allows 10). */
        const val MAX_SCALE_LIMIT = 10f
        const val MIN_MAX_SCALE = 0.1f

        /** Canvas pixels moved by one notch of a mouse wheel when scrolling pans. */
        const val SCROLL_PAN_STEP = 48f

        /** The factor one notch of a wheel zooms by; a fraction of a notch (a trackpad) zooms by that fraction of it. */
        const val ZOOM_PER_NOTCH = 1.1f

        /** The zoom factor for a scroll of [notches] (positive = scrolled down = zoom out). */
        fun zoomFactor(notches: Float): Float = Math.pow(ZOOM_PER_NOTCH.toDouble(), (-notches).toDouble()).toFloat()

        /** True for a drag long enough to count as moving (so a click with a little jitter is not a pan). */
        fun isMovement(delta: Offset): Boolean = abs(delta.x) + abs(delta.y) > 0.5f
    }
}
