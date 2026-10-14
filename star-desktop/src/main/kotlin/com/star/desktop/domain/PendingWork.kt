package com.star.desktop.domain

import com.star.desktop.i18n.localized

/**
 * What would be interrupted by closing the sequence or quitting (macOS `hasPendingWork` and `pendingWorkDescription`): a run, frames being
 * rendered again, a video being encoded, and edits still waiting to be written out.
 */
data class PendingWork(
    val processing: Boolean,
    val renderingFrames: Boolean,
    val renderingVideo: Boolean,
    /** Frames whose edits are being saved, or waiting their turn to be. */
    val savingFrames: Int,
) {
    val isPending: Boolean get() = processing || renderingFrames || renderingVideo || savingFrames > 0

    /** The work in words, for "Currently {0}. Closing now will interrupt this work.": "processing frames, rendering video, saving 3 frames". */
    fun description(): String {
        val parts = ArrayList<String>()
        // Re-rendering frames is the same kind of work to the person closing the window, and has no words of its own.
        if (processing || renderingFrames) parts += localized("ui.pending.processing_frames")
        if (renderingVideo) parts += localized("ui.pending.rendering_video")
        if (savingFrames > 0) {
            parts += if (savingFrames == 1) localized("ui.pending.saving_frame_one") else localized("ui.pending.saving_frames_many", savingFrames)
        }
        return parts.joinToString(", ")
    }

    companion object {
        val NONE = PendingWork(processing = false, renderingFrames = false, renderingVideo = false, savingFrames = 0)
    }
}

/** What a confirmation is about to do. */
enum class CloseAction(val messageKey: String, val confirmKey: String) {
    /** The window is closing, or Cmd-Q: the whole app goes. */
    QUIT("ui.work_in_progress.quitting", "ui.quit_anyway"),

    /** File ▸ Close: the sequence goes, the app stays. */
    CLOSE_SESSION("ui.work_in_progress.closing", "ui.stop_and_close"),
}

/** The question put to the user before work is interrupted: what is going on, and what is about to happen to it. */
data class CloseConfirmation(val action: CloseAction, val work: String) {
    val message: String get() = localized(action.messageKey, work)
}
