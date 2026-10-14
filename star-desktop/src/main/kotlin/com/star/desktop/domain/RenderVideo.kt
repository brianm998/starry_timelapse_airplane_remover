package com.star.desktop.domain

import com.star.desktop.i18n.localized
import com.star.proto.VideoCapabilities
import java.io.File
import java.util.Locale
import kotlin.math.abs

/**
 * Where the Render Video work has got to (macOS `RenderVideoSheetView`'s `isRendering`, `renderSuccess` and `renderingError`): choosing the settings,
 * rendering, done, or failed. Held by the app, not by the dialog, so that anything that has to ask whether a render is going (closing the window)
 * can see it.
 */
sealed interface RenderState {
    /** Nothing under way: the dialog shows its pickers. */
    data object Choosing : RenderState

    /** Frame [current] of [total] is being encoded into [fileName]. */
    data class Rendering(val fileName: String, val current: Int, val total: Int) : RenderState {
        /** How far along, 0 to 1; 0 until the first frame reports. */
        val fraction: Float get() = if (total > 0) (current.toFloat() / total).coerceIn(0f, 1f) else 0f
    }

    /** The video is written: [fileName] is what it is called, and [path] is where, as the daemon said (null from an engine that does not say). */
    data class Succeeded(val fileName: String, val path: String?) : RenderState

    data class Failed(val message: String) : RenderState
}

val RenderState.isRendering: Boolean get() = this is RenderState.Rendering

/** Small things the dialog says about a render, kept apart so they can be tested. */
object RenderVideo {
    /** A length of time as "1h 2m 3s": hours and minutes only when there are any (macOS `formatTimeInterval`). */
    fun formatLength(seconds: Double): String {
        val total = if (seconds.isFinite() && seconds > 0) seconds.toLong() else 0L
        val hours = total / 3600
        val minutes = total % 3600 / 60
        val parts = ArrayList<String>()
        if (hours > 0) parts += localized("duration.hours_minutes", hours, minutes)
        else if (minutes > 0) parts += localized("duration.minutes", minutes)
        parts += localized("duration.seconds", total % 60)
        return parts.joinToString(" ")
    }

    /** How long [frames] last at [frameRate] frames a second; 0 for a rate that is no rate. */
    fun lengthSeconds(frames: Int, frameRate: Double): Double = if (frameRate > 0 && frameRate.isFinite()) frames / frameRate else 0.0

    /** A frame rate as it is read aloud and typed: 29.97, 24, 12.5 (macOS `%g`). */
    fun rateText(rate: Double): String = String.format(Locale.ROOT, "%g", rate).let { if ('.' in it) it.trimEnd('0').trimEnd('.') else it }

    /** The file a path names. */
    fun fileName(path: String): String = File(path).name

    /** What the custom frame rate field accepts: a rate up to 1000 (macOS), above nothing at all (the daemon refuses 0). */
    const val CUSTOM_MIN = 0.01
    const val CUSTOM_MAX = 1000.0

    fun customRate(text: String): Double? = FieldInput.double(text, CUSTOM_MIN, CUSTOM_MAX)

    /**
     * The frame rate picker's entry for [rate]: the standard rate it equals, else Custom. The standard ones are the daemon's list; the entry that is
     * [custom] stands for every other rate.
     */
    fun rateEntry(caps: VideoCapabilities, rate: Double): com.star.proto.FrameRateCaps? {
        val entries = caps.frameRateCapsList
        return entries.firstOrNull { !it.custom && abs(it.value - rate) < 1e-9 } ?: entries.firstOrNull { it.custom }
    }
}
