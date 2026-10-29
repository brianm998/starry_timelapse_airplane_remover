package com.star.desktop.domain

import com.star.desktop.i18n.localized
import com.star.proto.FrameExtraction

/**
 * How fast each step of a run is finishing its operations, for the "about N left" under the processing screen's title (macOS `StepRateTracker`).
 * Measured from the first moment a step was seen working rather than from the start of the run: the steps overlap, so one that sat queued behind
 * the one before it would look slow for its whole turn. Nothing is estimated until a step has finished a couple of operations over a few seconds.
 */
class StepRateTracker {
    private class Sample(val timeMs: Long, val done: Int)

    private val starts = HashMap<String, Sample>()
    private val latest = HashMap<String, Sample>()

    fun observe(steps: List<StepRow>, nowMs: Long = System.currentTimeMillis()) {
        for (step in steps.filter { it.hasWork }) {
            val sample = Sample(nowMs, step.done)
            if (step.type !in starts && (step.running > 0 || step.done > 0)) starts[step.type] = sample
            latest[step.type] = sample
        }
    }

    /** Seconds [step] has left at the rate it has been going, or null while there is no rate to go on. */
    fun secondsRemaining(step: StepRow): Double? {
        val start = starts[step.type] ?: return null
        val now = latest[step.type] ?: return null
        val operations = now.done - start.done
        val seconds = (now.timeMs - start.timeMs) / 1000.0
        if (operations < MINIMUM_OPERATIONS || seconds < MINIMUM_SECONDS) return null
        return (step.queued + step.running) * seconds / operations
    }

    companion object {
        const val MINIMUM_OPERATIONS = 2
        const val MINIMUM_SECONDS = 3.0
    }
}

/** The one short sentence under the title that says what star is doing right now, and why, with how long it has left when that can be told. */
object ProcessingHeadline {
    private val ACTIVITY = mapOf(
        "horizon" to "ui.status.horizon", "mergedHorizon" to "ui.status.merged_horizon", "starKeypoints" to "ui.status.star_keypoints",
        "earthKeypoints" to "ui.status.earth_keypoints", "starHomography" to "ui.status.star_alignment",
        "earthHomography" to "ui.status.earth_alignment", "horizonConsensus" to "ui.status.horizon_consensus",
        "outliers" to "ui.status.outliers", "merge" to "ui.status.merged",
    )

    /** What [type] is doing and why, as one sentence; the longer account is the step's hover help. */
    fun activity(type: String): String = ACTIVITY[type]?.let { localized(it) } ?: ""

    /** [hasPlan] is whether the daemon has reported the run's operations yet; until then every step reads as empty, which is planning, not nothing to do. */
    fun text(
        steps: List<StepRow>,
        extraction: FrameExtraction?,
        hasPlan: Boolean,
        framesComplete: Int,
        frameCount: Int,
        secondsRemaining: (StepRow) -> Double?,
    ): String? {
        val working = steps.filter { it.hasWork && (it.queued > 0 || it.running > 0) }
        // The earliest unfinished step is the one the rest wait on; with several going at once, it sets the pace.
        val active = working.firstOrNull { it.running > 0 } ?: working.firstOrNull()

        if (extraction != null && extraction.active && !extraction.complete && extraction.error.isEmpty() && active == null) {
            return withEstimate(localized("ui.status.extracting"), extraction.etaSeconds.takeIf { extraction.etaKnown }, "ui.status.left_overall")
        }
        if (!hasPlan) return localized("ui.status.planning")
        if (active == null) {
            if (steps.isEmpty()) return null
            return if (framesComplete < frameCount) localized("ui.status.finishing") else null
        }
        return withEstimate(activity(active.type), secondsRemaining(active), "ui.status.left_step")
    }

    private fun withEstimate(sentence: String, seconds: Double?, key: String): String =
        if (seconds == null || !seconds.isFinite()) sentence else sentence + " " + localized(key, duration(seconds))

    /** Coarse on purpose: a figure to the second would imply an accuracy the rate does not have. */
    fun duration(seconds: Double): String {
        val total = Math.round(seconds.coerceAtLeast(0.0)).toInt()
        if (total < 60) return localized("duration.seconds", maxOf(5, (total + 2) / 5 * 5))
        val minutes = (total + 30) / 60
        if (minutes < 60) return localized("duration.minutes", minutes)
        return localized("duration.hours_minutes", minutes / 60, minutes % 60)
    }
}
