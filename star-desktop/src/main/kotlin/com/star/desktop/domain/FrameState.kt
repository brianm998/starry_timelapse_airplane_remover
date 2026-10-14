package com.star.desktop.domain

import com.star.desktop.i18n.localized
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

    /**
     * The state in the words the user reads, in their language (macOS `FrameProcessingState.message`: the same catalogue entries). An
     * alignment step is named as StarCore names it, without the neighbour number the proto's state does not carry.
     */
    fun message(s: FrameProcessingState): String = when (s) {
        FrameProcessingState.FPS_UNPROCESSED -> localized("frame_state.unprocessed")
        FrameProcessingState.FPS_HORIZON_DETECTION -> localized("frame_state.horizon_detection")
        FrameProcessingState.FPS_HORIZON_DETECTED -> localized("frame_state.horizon_detected")
        FrameProcessingState.FPS_MERGING_HORIZON -> localized("frame_state.merging_horizon")
        FrameProcessingState.FPS_EARTH_ALIGNMENT_START -> localized("frame_state.earth_alignment", "start")
        FrameProcessingState.FPS_EARTH_ALIGNMENT_BASE_KP -> localized("frame_state.earth_alignment", "base detect")
        FrameProcessingState.FPS_EARTH_ALIGNMENT_BASE_KP_DONE -> localized("frame_state.earth_alignment", "base done")
        FrameProcessingState.FPS_EARTH_ALIGNMENT_ALIGNING -> localized("frame_state.earth_alignment", "align")
        FrameProcessingState.FPS_EARTH_ALIGNMENT_LOADING -> localized("frame_state.earth_alignment", "load")
        FrameProcessingState.FPS_EARTH_ALIGNMENT_COMPLETE -> localized("frame_state.earth_alignment", "complete")
        FrameProcessingState.FPS_CREATING_EARTH_ALIGNED -> localized("frame_state.creating_earth_aligned_frame")
        FrameProcessingState.FPS_STAR_KEYPOINTS -> localized("frame_state.star_keypoints")
        FrameProcessingState.FPS_EARTH_KEYPOINTS -> localized("frame_state.earth_keypoints")
        FrameProcessingState.FPS_STAR_KEYPOINTS_FOUND -> localized("frame_state.star_keypoints_found")
        FrameProcessingState.FPS_EARTH_KEYPOINTS_FOUND -> localized("frame_state.earth_keypoints_found")
        FrameProcessingState.FPS_STAR_ALIGNMENT_START -> localized("frame_state.star_alignment", "start")
        FrameProcessingState.FPS_STAR_ALIGNMENT_BASE_KP -> localized("frame_state.star_alignment", "base detect")
        FrameProcessingState.FPS_STAR_ALIGNMENT_BASE_KP_DONE -> localized("frame_state.star_alignment", "base done")
        FrameProcessingState.FPS_STAR_ALIGNMENT_ALIGNING -> localized("frame_state.star_alignment", "align")
        FrameProcessingState.FPS_STAR_ALIGNMENT_LOADING -> localized("frame_state.star_alignment", "load")
        FrameProcessingState.FPS_STAR_ALIGNMENT_COMPLETE -> localized("frame_state.star_alignment", "complete")
        FrameProcessingState.FPS_STAR_ALIGNMENT_FAILED -> localized("frame_state.star_alignment_failed")
        FrameProcessingState.FPS_CREATING_STAR_ALIGNED -> localized("frame_state.creating_star_aligned_frame")
        FrameProcessingState.FPS_SUBTRACTING_NEIGHBOR -> localized("frame_state.subtracting_neighbor")
        FrameProcessingState.FPS_ASSEMBLING_PIXELS -> localized("frame_state.assembling_pixels")
        FrameProcessingState.FPS_SORTING_PIXELS -> localized("frame_state.sorting_pixels")
        FrameProcessingState.FPS_DETECTING_BLOBS -> localized("frame_state.detecting_blobs")
        FrameProcessingState.FPS_FILTER_1 -> localized("frame_state.filter", 1)
        FrameProcessingState.FPS_FILTER_2 -> localized("frame_state.filter", 2)
        FrameProcessingState.FPS_FILTER_3 -> localized("frame_state.filter", 3)
        FrameProcessingState.FPS_FILTER_4 -> localized("frame_state.filter", 4)
        FrameProcessingState.FPS_FILTER_5 -> localized("frame_state.filter", 5)
        FrameProcessingState.FPS_FILTER_6 -> localized("frame_state.filter", 6)
        FrameProcessingState.FPS_FILTER_7 -> localized("frame_state.filter", 7)
        FrameProcessingState.FPS_FILTER_8 -> localized("frame_state.filter", 8)
        FrameProcessingState.FPS_FIRST_CLASSIFICATION -> localized("frame_state.first_classification")
        FrameProcessingState.FPS_READY_FOR_INTER_FRAME -> localized("frame_state.ready_for_inter_frame_processing")
        FrameProcessingState.FPS_SECOND_CLASSIFICATION -> localized("frame_state.second_classification")
        FrameProcessingState.FPS_OUTLIER_PROCESSING_COMPLETE -> localized("frame_state.outlier_processing_complete")
        FrameProcessingState.FPS_FINISHING -> localized("frame_state.finishing")
        FrameProcessingState.FPS_USER_MODIFIED -> localized("frame_state.user_modified")
        FrameProcessingState.FPS_WRITING_OUTLIER_VALUES -> localized("frame_state.writing_outlier_values")
        FrameProcessingState.FPS_WAITING_TO_LOAD_IMAGES -> localized("frame_state.waiting_to_load_images")
        FrameProcessingState.FPS_LOADING_IMAGES -> localized("frame_state.loading_images")
        FrameProcessingState.FPS_LOADING_IMAGES_1 -> localized("frame_state.loading_images1")
        FrameProcessingState.FPS_CREATING_REMOVAL_MASK -> localized("frame_state.creating_removal_mask")
        FrameProcessingState.FPS_ASSEMBLING_PROCESSED_FRAME -> localized("frame_state.assembling_processed_frame")
        FrameProcessingState.FPS_WRITING_OUTPUT_FILE -> localized("frame_state.writing_output_file")
        FrameProcessingState.FPS_COMPLETE -> localized("frame_state.complete")
        FrameProcessingState.UNRECOGNIZED -> ""
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
