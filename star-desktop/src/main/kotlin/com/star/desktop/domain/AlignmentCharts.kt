package com.star.desktop.domain

import com.star.desktop.i18n.localized
import com.star.proto.AlignmentInfo
import com.star.proto.AlignmentState
import com.star.proto.HomographyResults
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/** One reading on the deviation chart: how far [frame]'s alignment to the neighbor [offset] frames away moved the picture (macOS `DeviationPoint`). */
data class DeviationPoint(
    val frame: Int,
    /** The neighbor's frame index less [frame]. Never 0: a frame's own entry is not a reading. */
    val offset: Int,
    /** Drawn signed by the offset, so the neighbors before and after a frame separate on the chart. */
    val deviation: Double,
    val state: AlignmentState,
    /** False for a warp the per-frame heuristics distrust: drawn red. Distrusted is not unused; the frame's set is kept whole while enough of it stands up. */
    val isGood: Boolean,
) {
    /** "+2" or "-3": how the legend and tooltip say an offset. */
    val offsetLabel: String get() = AlignmentCharts.offsetLabel(offset)

    val stateLabel: String get() = AlignmentCharts.stateLabel(state)
}

/**
 * What the alignment charts draw, read from `Alignment.GetSequence`: the deviation readings of the star and earth alignment, and how many
 * keypoints each frame had (macOS `starAlignmentInfo`, `earthAlignmentInfo`, `skyKeypointCounts`, `earthKeypointCounts`).
 */
class AlignmentData(val frames: List<AlignmentInfo>) {
    val frameCount: Int get() = frames.size

    /** Whether earth alignment is on, which is what says there are earth charts at all. */
    val allowEarth: Boolean = frames.any { it.allowEarthAlignment }

    val hasStar: Boolean = frames.any { it.hasStarResults }
    val hasEarth: Boolean = frames.any { it.hasEarthResults }

    val starPoints: List<DeviationPoint> = AlignmentCharts.points(frames) { if (it.hasStarResults) it.star else null }
    val earthPoints: List<DeviationPoint> = AlignmentCharts.points(frames) { if (it.hasEarthResults) it.earth else null }

    /** Keypoints found in each frame's sky and ground, by frame; null where they were not known (features not loaded). */
    val skyKeypoints: List<Int?> = frames.map { f -> f.numSkyKeypoints.takeIf { it >= 0 } }
    val earthKeypoints: List<Int?> = frames.map { f -> f.numEarthKeypoints.takeIf { it >= 0 } }

    companion object {
        val EMPTY = AlignmentData(emptyList())
    }
}

object AlignmentCharts {
    /** The chart's colours cycle through this many, by how far away the neighbor is (macOS `Color.byOffset`). */
    const val PALETTE_SIZE = 8

    /** Which colour an offset gets: the nearest neighbors take the first colours, and an offset and its negative the same one. */
    fun paletteIndex(offset: Int): Int = Math.floorMod(abs(offset) - 1, PALETTE_SIZE)

    fun offsetLabel(offset: Int): String = if (offset > 0) "+$offset" else "$offset"

    fun stateLabel(state: AlignmentState): String = when (state) {
        AlignmentState.ALIGN_UNABLE_TO_DETECT_KEYPOINTS -> localized("alignment_state.unable_to_detect_keypoints")
        AlignmentState.ALIGN_NOT_ENOUGH_KEYPOINTS -> localized("alignment_state.not_enough_keypoints")
        AlignmentState.ALIGN_NO_HOMOGRAPHY_FOUND -> localized("alignment_state.no_homography_found")
        AlignmentState.ALIGN_HOMOGRAPHY_SUCCESS -> localized("alignment_state.homography_success")
        AlignmentState.ALIGN_USED_EXISTING_HOMOGRAPHY -> localized("alignment_state.used_existing_homography")
        AlignmentState.ALIGN_NO_ALIGNMENT -> localized("alignment_state.no_alignment")
        else -> localized("alignment_state.unknown")
    }

    /** Flatten every frame's neighbor set into readings (macOS `AlignmentDeviationChart.deviationPoints`), skipping each frame's own entry. */
    fun points(frames: List<AlignmentInfo>, results: (AlignmentInfo) -> HomographyResults?): List<DeviationPoint> {
        val out = ArrayList<DeviationPoint>()
        for (f in frames) {
            val r = results(f) ?: continue
            for (n in r.neighborsList) {
                val offset = n.frameIndex - f.frameIndex
                if (offset == 0) continue
                out += DeviationPoint(f.frameIndex, offset, if (offset > 0) n.deviation else -n.deviation, n.state, isGood = !n.suspect)
            }
        }
        return out
    }

    /** One polyline per neighbor offset, in offset order, each in frame order: without the grouping every offset's end would join the next one's start. */
    fun byOffset(points: List<DeviationPoint>): List<Pair<Int, List<DeviationPoint>>> =
        points.groupBy { it.offset }.toSortedMap().map { (offset, pts) -> offset to pts.sortedBy { it.frame } }

    /** The offsets worth a legend entry: those of the series that are showing. */
    fun visibleOffsets(vararg shown: List<DeviationPoint>): List<Int> = shown.flatMap { pts -> pts.map { it.offset } }.toSortedSet().toList()

    /** The reading under the pointer: of the [frame]'s readings, the one nearest [deviation] up the chart. */
    fun closest(points: List<DeviationPoint>, frame: Int, deviation: Double): DeviationPoint? =
        points.filter { it.frame == frame }.minByOrNull { abs(it.deviation - deviation) }

    /** The frame an x position over a plot [width] wide names, when the plot shows [domain]. */
    fun frameAt(x: Float, width: Float, domain: XDomain): Int {
        if (width <= 0f) return domain.lower
        return (domain.lower + (x / width).coerceIn(0f, 1f) * domain.span).roundToInt().coerceIn(domain.lower, domain.upper)
    }

    /** The "Height" slider: the charts draw a fixed range either side of zero rather than fit the data, so one wild reading cannot flatten the rest. */
    const val MIN_HEIGHT = 5.0
    const val MAX_HEIGHT = 100.0
    const val DEFAULT_HEIGHT = 50.0
}

/** The frames a chart shows along its x axis, zoomed and panned (macOS `xDomain`). Frame numbers, inclusive. */
data class XDomain(val lower: Int, val upper: Int) {
    val span: Int get() = upper - lower

    operator fun contains(frame: Int): Boolean = frame in lower..upper

    /**
     * Zoomed by [factor] (above 1 zooms in) about [anchor], the frame under the pointer, which stays where it is on screen. Never narrower
     * than [MIN_SPAN] frames (or the whole sequence when it is shorter than that), nor wider than the sequence.
     */
    fun zoomed(factor: Double, frameCount: Int, anchor: Double = (lower + upper) / 2.0): XDomain {
        val maxFrame = frameCount - 1
        if (maxFrame <= 0 || factor <= 0.0) return this
        val newSpan = (span / factor).roundToInt().coerceIn(min(MIN_SPAN, maxFrame), maxFrame)
        val relative = if (span == 0) 0.5 else ((anchor - lower) / span).coerceIn(0.0, 1.0)
        val newLower = (anchor - relative * newSpan).roundToInt().coerceIn(0, maxFrame - newSpan)
        return XDomain(newLower, newLower + newSpan)
    }

    /** Moved by [frames] (positive shows later frames), keeping its width. */
    fun panned(frames: Int, frameCount: Int): XDomain {
        val maxFrame = max(frameCount - 1, 0)
        val width = min(span, maxFrame)
        val newLower = (lower + frames).coerceIn(0, maxFrame - width)
        return XDomain(newLower, newLower + width)
    }

    /** This, moved if it must be so that [frame] is in it: the chart follows the current frame instead of leaving it off screen. */
    fun ensuring(frame: Int, frameCount: Int): XDomain {
        if (frame in this) return this
        val maxFrame = max(frameCount - 1, 0)
        val width = min(span, maxFrame)
        val newLower = (frame - width / 2).coerceIn(0, maxFrame - width)
        return XDomain(newLower, newLower + width)
    }

    companion object {
        const val MIN_SPAN = 20

        fun full(frameCount: Int) = XDomain(0, max(frameCount - 1, 0))
    }
}

/** Where the tick marks on a chart's axes go. */
object ChartTicks {
    /** Round values from [min] to [max], about [approxCount] of them: steps of 1, 2 or 5 times a power of ten. */
    fun nice(min: Double, max: Double, approxCount: Int): List<Double> {
        if (!(max > min) || approxCount < 1) return listOf(min)
        val rough = (max - min) / approxCount
        val magnitude = Math.pow(10.0, Math.floor(Math.log10(rough)))
        val residual = rough / magnitude
        val step = magnitude * when {
            residual <= 1.0 -> 1.0
            residual <= 2.0 -> 2.0
            residual <= 5.0 -> 5.0
            else -> 10.0
        }
        val first = Math.ceil(min / step) * step
        val out = ArrayList<Double>()
        var v = first
        while (v <= max + step * 1e-9) {
            out += if (abs(v) < step * 1e-9) 0.0 else v
            v += step
        }
        return out
    }

    /** A tick's text: whole numbers plain, anything else to one decimal. */
    fun label(value: Double): String = if (value == Math.rint(value)) value.toLong().toString() else String.format(java.util.Locale.ROOT, "%.1f", value)
}
