package com.star.desktop.domain

import com.star.desktop.i18n.localized
import com.star.proto.FrameViewMode

/** The images the pipeline keeps for a frame, and how the left panel's "Show" list offers them (macOS `FrameViewMode`). */
object ViewModes {
    /** Every mode, in macOS's order. */
    val all: List<FrameViewMode> = listOf(
        FrameViewMode.VIEW_ORIGINAL, FrameViewMode.VIEW_HORIZON, FrameViewMode.VIEW_MERGED_HORIZON, FrameViewMode.VIEW_USER_HORIZON,
        FrameViewMode.VIEW_CONSENSUS_HORIZON,
        FrameViewMode.VIEW_STAR_ALIGNED, FrameViewMode.VIEW_FAILED_STAR_ALIGNED, FrameViewMode.VIEW_EARTH_ALIGNED, FrameViewMode.VIEW_FAILED_EARTH_ALIGNED,
        FrameViewMode.VIEW_SUBTRACTION, FrameViewMode.VIEW_BLOBS, FrameViewMode.VIEW_VALIDATION, FrameViewMode.VIEW_REMOVE_MASK,
        FrameViewMode.VIEW_AUTO_PROCESSED, FrameViewMode.VIEW_AUTO_SELECTIVE_PROCESSED, FrameViewMode.VIEW_SELECTIVE_PROCESSED,
        FrameViewMode.VIEW_PROCESSED,
    )

    /** The few worth a place in the list until it is expanded. */
    private val BASIC = setOf(FrameViewMode.VIEW_ORIGINAL, FrameViewMode.VIEW_PROCESSED, FrameViewMode.VIEW_USER_HORIZON)

    /** The modes to list: those the frame has an image of, all of them or, collapsed, only the basic ones. */
    fun shown(available: Collection<FrameViewMode>, expanded: Boolean): List<FrameViewMode> =
        all.filter { it in available && (expanded || it in BASIC) }

    /** The catalogue entry for the mode's name (`view_mode.<macOS case name>`). */
    private fun key(mode: FrameViewMode): String? = when (mode) {
        FrameViewMode.VIEW_ORIGINAL -> "original"
        FrameViewMode.VIEW_HORIZON -> "horizon"
        FrameViewMode.VIEW_MERGED_HORIZON -> "mergedHorizon"
        FrameViewMode.VIEW_USER_HORIZON -> "userHorizon"
        FrameViewMode.VIEW_CONSENSUS_HORIZON -> "consensusHorizon"
        FrameViewMode.VIEW_STAR_ALIGNED -> "starAligned"
        FrameViewMode.VIEW_FAILED_STAR_ALIGNED -> "failedStarAligned"
        FrameViewMode.VIEW_EARTH_ALIGNED -> "earthAligned"
        FrameViewMode.VIEW_FAILED_EARTH_ALIGNED -> "failedEarthAligned"
        FrameViewMode.VIEW_SUBTRACTION -> "subtraction"
        FrameViewMode.VIEW_BLOBS -> "blobs"
        FrameViewMode.VIEW_VALIDATION -> "validation"
        FrameViewMode.VIEW_REMOVE_MASK -> "removeMask"
        FrameViewMode.VIEW_AUTO_PROCESSED -> "autoProcessed"
        FrameViewMode.VIEW_AUTO_SELECTIVE_PROCESSED -> "autoSelectiveProcessed"
        FrameViewMode.VIEW_SELECTIVE_PROCESSED -> "selectiveProcessed"
        FrameViewMode.VIEW_PROCESSED -> "final"
        FrameViewMode.UNRECOGNIZED -> null
    }

    /** The mode's name in the user's language ("final processed frame"). */
    fun longName(mode: FrameViewMode): String = key(mode)?.let { localized("view_mode.$it") } ?: ""
}
