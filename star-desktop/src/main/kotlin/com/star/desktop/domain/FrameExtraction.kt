package com.star.desktop.domain

import com.star.proto.FrameRange

/**
 * Which frames of a video are extracted, as sorted, disjoint, non-adjacent ranges (the form the daemon sends them in, and the form the scrub
 * slider's band draws). Immutable: an arrival makes a new one.
 */
class ExtractedFrames private constructor(val ranges: List<IntRange>) {

    /** How many frames there are. */
    val count: Int get() = ranges.sumOf { it.last - it.first + 1 }

    operator fun contains(index: Int): Boolean {
        // binary search over the ranges: the filmstrip asks once per cell per redraw
        var lo = 0
        var hi = ranges.size - 1
        while (lo <= hi) {
            val mid = (lo + hi) ushr 1
            val r = ranges[mid]
            when {
                index < r.first -> hi = mid - 1
                index > r.last -> lo = mid + 1
                else -> return true
            }
        }
        return false
    }

    /** These frames and [other] ones, joined where they touch. */
    operator fun plus(other: List<IntRange>): ExtractedFrames = of(ranges + other)

    /** The first frame at or after [from] that is not extracted. */
    fun firstMissingFrom(from: Int): Int {
        var next = from
        for (r in ranges) {
            if (r.last < next) continue
            if (r.first > next) break
            next = r.last + 1
        }
        return next
    }

    override fun equals(other: Any?): Boolean = other is ExtractedFrames && other.ranges == ranges
    override fun hashCode(): Int = ranges.hashCode()
    override fun toString(): String = "ExtractedFrames($ranges)"

    companion object {
        val NONE = ExtractedFrames(emptyList())

        /** [ranges] in any order, overlapping or touching or not, as one set. Empty ones are dropped. */
        fun of(ranges: List<IntRange>): ExtractedFrames {
            val sorted = ranges.filter { !it.isEmpty() }.sortedBy { it.first }
            val merged = ArrayList<IntRange>(sorted.size)
            for (r in sorted) {
                val last = merged.lastOrNull()
                if (last != null && r.first <= last.last + 1) merged[merged.size - 1] = last.first..maxOf(last.last, r.last)
                else merged.add(r)
            }
            return ExtractedFrames(merged)
        }

        /** The wire's half-open `[start, end)` ranges. */
        fun fromProto(ranges: List<FrameRange>): ExtractedFrames = of(ranges.map { it.start until it.end })
    }
}

/** What the extraction of a video says about itself in words and numbers: the same wherever it is drawn. */
object ExtractionFormat {

    /** "5 s", "4 min", "1 h 20 min": about how long, in the unit that reads best. */
    fun duration(seconds: Double): String {
        val rounded = Math.ceil(seconds.coerceAtLeast(0.0)).toInt()
        if (rounded < 90) return "${maxOf(1, rounded)} s"
        val minutes = Math.round(rounded / 60.0).toInt()
        if (minutes < 90) return "$minutes min"
        return "${minutes / 60} h ${minutes % 60} min"
    }

    /** How far along the wait for a frame is: the sweep's share of the way to it, for a frame that waits for the in-order extraction. */
    fun sweepFraction(sweepHead: Int, frame: Int): Double =
        if (frame <= 0) 1.0 else (sweepHead.toDouble() / frame).coerceIn(0.0, 1.0)
}
