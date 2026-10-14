package com.star.desktop.domain

import com.star.desktop.i18n.localized
import com.star.proto.StepProgress

/**
 * One bar of the processing screen (macOS `ProcessingStepProgress`): how far one step of the run has got, over the whole of what it has
 * to cover. The counts are operations, which is what there is to count: most steps have one per frame, but a frame whose work was
 * already on disk has none ([alreadyDone], which belongs at the finished end of the bar), so a sequence resumed half way reads as half done.
 */
data class StepRow(val type: String, val queued: Int, val running: Int, val done: Int, val alreadyDone: Int) {
    /** Every frame this step covers, whoever did it and whenever. */
    val total: Int get() = alreadyDone + queued + running + done

    /** Frames of this step that are finished, this run's and any earlier run's alike. */
    val completed: Int get() = alreadyDone + done

    /** False for a step with nothing to it at all: no operations, and nothing already on disk that they would have produced. */
    val hasWork: Boolean get() = total > 0

    val doneFraction: Float get() = fraction(completed)
    val runningFraction: Float get() = fraction(running)

    private fun fraction(count: Int): Float = if (total > 0) count.toFloat() / total else 0f

    /** What the screen calls this step: a noun, from the entries the Mac app's labels come from. */
    val name: String get() = nameKey(type)?.let { localized(it) } ?: type

    /** The name, then what the step is and what it costs: the hover help on its row. */
    val help: String
        get() {
            val key = helpKey(type) ?: return name
            return "$name\n\n${localized(key)}"
        }

    companion object {
        private val NAMES = mapOf(
            "horizon" to "ui.horizon", "mergedHorizon" to "ui.merged_horizon", "starKeypoints" to "ui.star_keypoints",
            "earthKeypoints" to "ui.earth_keypoints", "starHomography" to "ui.star_alignment", "earthHomography" to "ui.earth_alignment",
            "outliers" to "ui.outliers", "merge" to "ui.merged",
        )

        private val HELPS = mapOf(
            "horizon" to "ui.step_help.horizon", "mergedHorizon" to "ui.step_help.merged_horizon", "starKeypoints" to "ui.step_help.star_keypoints",
            "earthKeypoints" to "ui.step_help.earth_keypoints", "starHomography" to "ui.step_help.star_alignment",
            "earthHomography" to "ui.step_help.earth_alignment", "outliers" to "ui.step_help.outliers", "merge" to "ui.step_help.merged",
        )

        fun nameKey(type: String): String? = NAMES[type]
        fun helpKey(type: String): String? = HELPS[type]

        /** The rows in a report from the daemon, in the order it sent them (the order the screen stacks them). */
        fun of(report: StepProgress?): List<StepRow> =
            report?.stepsList?.map { StepRow(it.type, it.queued, it.running, it.done, it.alreadyDone) } ?: emptyList()
    }
}
