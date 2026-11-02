package com.star.desktop.domain

import com.star.desktop.i18n.localized
import com.star.proto.CleanMethod

/**
 * What the info dialog beside the Processing Frames "Steps" heading says (macOS `ProcessingStepsInfo`): an opening that names the kind of
 * video and the processing mode, then one entry per step the panel is showing, saying what it does and which earlier step's results it relies
 * on and why. A pure function of what the panel already knows, so that it can be tested without a screen: the dialog must never list a step
 * the panel does not show.
 */
data class ProcessingStepsInfo(val intro: String, val subtitle: String, val entries: List<Entry>) {
    /** One step as the dialog describes it; [id] is the daemon's type string, or `"extraction"` for the frame extraction row. */
    data class Entry(val id: String, val name: String, val what: String, val needs: String)

    companion object {
        private val NEEDS = mapOf(
            "horizon" to "ui.steps_info.needs.horizon", "mergedHorizon" to "ui.steps_info.needs.merged_horizon",
            "starKeypoints" to "ui.steps_info.needs.star_keypoints", "earthKeypoints" to "ui.steps_info.needs.earth_keypoints",
            "starHomography" to "ui.steps_info.needs.star_alignment", "earthHomography" to "ui.steps_info.needs.earth_alignment",
            "horizonConsensus" to "ui.steps_info.needs.horizon_consensus", "outliers" to "ui.steps_info.needs.outliers",
            "merge" to "ui.steps_info.needs.merged",
        )

        /**
         * Frame extraction first when the panel shows that row, then exactly [stepTypes] (the panel's rows, in its order). A type the panel
         * has no row for is skipped.
         */
        fun of(cameraMoving: Boolean, cleanMethod: CleanMethod?, stepTypes: List<String>, showsExtraction: Boolean): ProcessingStepsInfo {
            val entries = mutableListOf<Entry>()
            if (showsExtraction) {
                entries += Entry(
                    "extraction", localized("ui.processing_step_extracting_video"),
                    localized("ui.steps_info.extraction.what"), localized("ui.steps_info.needs.extraction"),
                )
            }
            for (type in stepTypes) {
                val needsKey = NEEDS[type] ?: continue
                val helpKey = StepRow.helpKey(type) ?: continue
                val name = StepRow.nameKey(type)?.let { localized(it) } ?: type
                // The first paragraph of the step's help: what it does, without the paragraph on what it costs.
                entries += Entry(type, name, localized(helpKey).substringBefore("\n\n"), localized(needsKey))
            }
            return ProcessingStepsInfo(
                intro = localized(if (cameraMoving) "ui.steps_info_intro_moving" else "ui.steps_info_intro_static", modeName(cleanMethod)),
                subtitle = localized("ui.steps_info_subtitle"),
                entries = entries,
            )
        }

        /** The same three names the grid's right panel gives the modes. */
        fun modeName(cleanMethod: CleanMethod?): String = localized(
            when (cleanMethod) {
                CleanMethod.CLEAN_AUTOMATIC_TRUE -> "ui.auto_selective"
                CleanMethod.CLEAN_AUTOMATIC -> "ui.automatic"
                else -> "ui.selective"
            },
        )
    }
}
