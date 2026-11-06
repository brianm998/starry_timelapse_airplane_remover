package com.star.desktop.ui.windows

/**
 * What the alignment window says besides its charts' numbers, as catalogue keys, shared with the gui through
 * `gherkin/ui/vectors/alignmentWindow.json` (the gui is the reference; `AlignmentWindowTextsTest` and the gui's `AlignmentWindowTextsTests` hold
 * both to the file).
 */
object AlignmentWindowTexts {
    const val NO_SEQUENCE = "ui.no_image_sequence_loaded"
    const val LOAD_A_SEQUENCE = "ui.load_an_image_sequence_in_the_main_star"
    const val WAITING = "ui.waiting_for_alignment_data"
    const val PROCESS_FIRST = "ui.no_alignment_data_process_the_sequence_first"

    /** The line over the charts: Ctrl+scroll (⌘+scroll on a Mac) zooms, dragging pans, clicking goes to that frame. */
    const val HELP = "ui.alignment_chart_help"

    const val CURRENT_FRAME = "ui.current_frame"
    const val HOVER_FRAME = "ui.hover_frame"
    const val KEYPOINT_SERIES = "ui.keypoints_title"
    const val KEYPOINT_VALUE = "ui.key_points"
    const val FRAME = "ui.frame_capitalised"
    const val X_AXIS = "ui.frame_index"
    const val KEYPOINT_Y_AXIS = "ui.number_of_key_points"
    const val STAR_KEYPOINTS_TITLE = "ui.star_keypoints"
    const val EARTH_KEYPOINTS_TITLE = "ui.earth_keypoints"

    /**
     * The catalogue keys, in order, the window shows in place of its charts: nothing when there is data to chart. [fetched] is whether the data
     * has been asked for and answered; [processing] whether a run is in progress (which may yet produce some).
     */
    fun emptyState(hasSequence: Boolean, fetched: Boolean, hasData: Boolean, processing: Boolean): List<String> = when {
        !hasSequence -> listOf(NO_SEQUENCE, LOAD_A_SEQUENCE)
        hasData -> emptyList()
        !fetched || processing -> listOf(WAITING)
        else -> listOf(PROCESS_FIRST)
    }
}
