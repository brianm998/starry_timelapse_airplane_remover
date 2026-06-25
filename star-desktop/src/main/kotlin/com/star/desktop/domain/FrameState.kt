package com.star.desktop.domain

import com.star.proto.FrameProcessingState

/** Display helpers over the proto [FrameProcessingState] (mirrors StarCore `FrameProcessingState`). */
object FrameState {

    fun isComplete(s: FrameProcessingState): Boolean = s == FrameProcessingState.FPS_COMPLETE
    fun isUnprocessed(s: FrameProcessingState): Boolean = s == FrameProcessingState.FPS_UNPROCESSED

    /** Rough 0..1 progress for a per-frame bar (ordinal over the COMPLETE ordinal). */
    fun fraction(s: FrameProcessingState): Float {
        val max = FrameProcessingState.FPS_COMPLETE.number.toFloat().coerceAtLeast(1f)
        return (s.number.toFloat() / max).coerceIn(0f, 1f)
    }

    /** A short human label for filmstrip/grid badges. */
    fun shortString(s: FrameProcessingState): String = SHORT[s] ?: prettify(s.name)

    private val SHORT: Map<FrameProcessingState, String> = mapOf(
        FrameProcessingState.FPS_UNPROCESSED to "unprocessed",
        FrameProcessingState.FPS_HORIZON_DETECTION to "horizon",
        FrameProcessingState.FPS_DETECTING_BLOBS to "blobs",
        FrameProcessingState.FPS_FIRST_CLASSIFICATION to "classifying",
        FrameProcessingState.FPS_READY_FOR_INTER_FRAME to "interframe",
        FrameProcessingState.FPS_SECOND_CLASSIFICATION to "classifying 2",
        FrameProcessingState.FPS_OUTLIER_PROCESSING_COMPLETE to "outliers done",
        FrameProcessingState.FPS_LOADING_IMAGES to "loading",
        FrameProcessingState.FPS_WRITING_OUTPUT_FILE to "writing",
        FrameProcessingState.FPS_FINISHING to "finishing",
        FrameProcessingState.FPS_USER_MODIFIED to "edited",
        FrameProcessingState.FPS_COMPLETE to "complete",
    )

    private fun prettify(enumName: String): String =
        enumName.removePrefix("FPS_").lowercase().replace('_', ' ')
}
