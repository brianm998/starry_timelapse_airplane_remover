package com.star.desktop.domain

import com.star.proto.FrameProcessingState

/** Display helpers over the proto [FrameProcessingState] (mirrors StarCore `FrameProcessingState`). */
object FrameState {

    fun isComplete(s: FrameProcessingState): Boolean = s == FrameProcessingState.FPS_COMPLETE
    fun isUnprocessed(s: FrameProcessingState): Boolean = s == FrameProcessingState.FPS_UNPROCESSED

    /**
     * Whether [s] is a stage a frame is in while something is being done to it (finding keypoints, aligning, filtering...), as
     * opposed to one it rests in until its next stage starts (horizon detected, keypoints found, ready for the inter-frame
     * work) or is finished or untouched in. The count of these stands for macOS's "frames processing now".
     */
    fun isWorking(s: FrameProcessingState): Boolean = s !in RESTING

    private val RESTING: Set<FrameProcessingState> = setOf(
        FrameProcessingState.FPS_UNPROCESSED,
        FrameProcessingState.FPS_HORIZON_DETECTED,
        FrameProcessingState.FPS_EARTH_ALIGNMENT_BASE_KP_DONE,
        FrameProcessingState.FPS_EARTH_ALIGNMENT_COMPLETE,
        FrameProcessingState.FPS_STAR_KEYPOINTS_FOUND,
        FrameProcessingState.FPS_EARTH_KEYPOINTS_FOUND,
        FrameProcessingState.FPS_STAR_ALIGNMENT_BASE_KP_DONE,
        FrameProcessingState.FPS_STAR_ALIGNMENT_COMPLETE,
        FrameProcessingState.FPS_STAR_ALIGNMENT_FAILED,
        FrameProcessingState.FPS_READY_FOR_INTER_FRAME,
        FrameProcessingState.FPS_OUTLIER_PROCESSING_COMPLETE,
        FrameProcessingState.FPS_USER_MODIFIED,
        FrameProcessingState.FPS_WAITING_TO_LOAD_IMAGES,
        FrameProcessingState.FPS_COMPLETE,
        FrameProcessingState.UNRECOGNIZED,
    )

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
