package com.star.desktop.domain

import com.star.proto.FrameProcessingState

/**
 * What the Process / Show Progress button offers (macOS `ProcessingButtonRole`): two different buttons sharing one place. While a run is going it
 * is the only way back to a processing screen that was dismissed, and it must never be disabled; otherwise it opens the settings, from
 * where a run is started.
 */
sealed interface ProcessingButtonRole {
    /** Puts the processing screen back up. Starts nothing. */
    data object Status : ProcessingButtonRole

    /** Opens the settings; disabled when there is nothing left to process. */
    data class Process(val enabled: Boolean) : ProcessingButtonRole

    companion object {
        /**
         * Nothing is left when no frame is untouched, and not the one other state worth processing from (every frame stopped at horizon
         * detection), and no reference horizon is waiting to be applied (work a finished sequence can still be owed). Also off while a
         * render is going.
         */
        fun current(
            isProcessing: Boolean,
            isRendering: Boolean,
            counts: FrameStateCounts,
            frameCount: Int,
            pendingHorizonRefinement: Boolean,
        ): ProcessingButtonRole {
            if (isProcessing) return Status
            val nothingToDo = counts.unprocessed == 0 &&
                counts[FrameProcessingState.FPS_HORIZON_DETECTED] != frameCount &&
                !pendingHorizonRefinement
            return Process(enabled = !nothingToDo && !isRendering)
        }
    }
}

/**
 * Which of the bottom bar's two buttons are on screen (macOS `ProcessingButtonsLayout`).
 *
 * "Render Video" is there only once processing is complete (every frame finished, no run going, no horizon reference still waiting to
 * be applied), because before that there is nothing to make a video from. The Process button gives its place up to it at the same
 * moment: a finished sequence has nothing left to process, and the two side by side took more of the bar than a disabled button is
 * worth. A sequence with no frames is never complete; there is nothing to render, and the Process button is where the user starts.
 */
data class ProcessingButtonsLayout(
    val showsProcess: Boolean,
    val showsRender: Boolean,
    /** A video being written holds off a second one, so Render stays on screen but off. */
    val renderEnabled: Boolean,
) {
    companion object {
        fun current(
            isProcessing: Boolean,
            isRendering: Boolean,
            completeCount: Int,
            frameCount: Int,
            pendingHorizonRefinement: Boolean,
        ): ProcessingButtonsLayout {
            val complete = frameCount > 0 && completeCount == frameCount && !isProcessing && !pendingHorizonRefinement
            return ProcessingButtonsLayout(showsProcess = !complete, showsRender = complete, renderEnabled = complete && !isRendering)
        }
    }
}

/** How many frames are in each processing state. A frame the daemon has not reported on yet is unprocessed. */
class FrameStateCounts(states: Map<Int, FrameProcessingState>, private val frameCount: Int) {
    private val byState: Map<FrameProcessingState, Int> = states.values.groupingBy { it }.eachCount()

    operator fun get(state: FrameProcessingState): Int =
        if (state == FrameProcessingState.FPS_UNPROCESSED) unprocessed else byState[state] ?: 0

    val unprocessed: Int = (byState[FrameProcessingState.FPS_UNPROCESSED] ?: 0) + (frameCount - states.size).coerceAtLeast(0)
    val complete: Int get() = byState[FrameProcessingState.FPS_COMPLETE] ?: 0

    /** Frames being worked on now (see [FrameState.isWorking]); stands for macOS's "frames processing now". */
    val working: Int = byState.entries.filter { FrameState.isWorking(it.key) }.sumOf { it.value }

    /** The three segments of the progress bar, as fractions of the sequence: finished, being worked on, not started. */
    fun fractions(): Triple<Float, Float, Float> {
        val total = frameCount.coerceAtLeast(1).toFloat()
        return Triple(complete / total, working / total, unprocessed / total)
    }
}
