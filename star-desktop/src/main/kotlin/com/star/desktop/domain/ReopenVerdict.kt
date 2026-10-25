package com.star.desktop.domain

import com.star.proto.SequenceProgress

/**
 * What the panel shown when a sequence is reopened says about it, and the one thing it offers to do about it (macOS `SequenceProgressPanel`).
 * The facts it turns on, whether every frame is written, whether what is on disk will be made again, and whether nothing at all was done, are the daemon's call (they come with the
 * survey), so this is only the choice of words and button.
 */
enum class ReopenVerdict(val statusKey: String, val actionKey: String, val actionHelpKey: String) {
    /** Every frame has its output written: the one thing left is the video. */
    COMPLETE("ui.processing_complete", "ui.render_video", "ui.render_all_frames_of_this_sequence_with"),

    /** Nothing has been done to the sequence yet. */
    UNTOUCHED("ui.this_sequence_has_not_been_processed_yet", "ui.start_processing", "ui.process_the_frames_that_are_not_finished"),

    /** Work on disk was made by other settings or an older star, so the next run makes it again: the same button, with the reason. */
    REBUILD("ui.this_sequence_needs_rebuilding", "ui.finish_processing", "ui.process_the_frames_that_are_not_finished"),

    /** Some of the work is done; the same button, said as finishing it. */
    PARTIAL("ui.this_sequence_is_partly_processed", "ui.finish_processing", "ui.process_the_frames_that_are_not_finished"),
    ;

    /** Whether the action is a render rather than a run: offering a render of a sequence with unwritten frames would offer a video with holes in it. */
    val rendersVideo: Boolean get() = this == COMPLETE

    companion object {
        fun of(progress: SequenceProgress): ReopenVerdict = when {
            progress.isComplete -> COMPLETE
            progress.needsRebuild -> REBUILD
            progress.isUntouched -> UNTOUCHED
            else -> PARTIAL
        }
    }
}
