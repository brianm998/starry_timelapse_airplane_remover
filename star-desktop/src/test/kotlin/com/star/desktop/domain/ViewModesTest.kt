package com.star.desktop.domain

import com.star.proto.FrameViewMode
import kotlin.test.Test
import kotlin.test.assertEquals

/** Q2 of the parity plan: the grid's Show list is the macOS one, not a fixed four. */
class ViewModesTest {
    @Test fun theGridAlwaysOffersTheOriginalAndTheFinalFrame() {
        assertEquals(listOf(FrameViewMode.VIEW_ORIGINAL, FrameViewMode.VIEW_PROCESSED), ViewModes.gridShown(emptyList()))
    }

    @Test fun andEveryOtherModeThereIsAnImageOf() {
        val shown = ViewModes.gridShown(listOf(FrameViewMode.VIEW_STAR_ALIGNED, FrameViewMode.VIEW_USER_HORIZON, FrameViewMode.VIEW_SUBTRACTION))
        assertEquals(
            listOf(
                FrameViewMode.VIEW_ORIGINAL, FrameViewMode.VIEW_USER_HORIZON, FrameViewMode.VIEW_STAR_ALIGNED,
                FrameViewMode.VIEW_SUBTRACTION, FrameViewMode.VIEW_PROCESSED,
            ),
            shown, "macOS's order, with the final last",
        )
    }

    @Test fun aModeWithNoImageIsNotListed() {
        assertEquals(false, FrameViewMode.VIEW_VALIDATION in ViewModes.gridShown(listOf(FrameViewMode.VIEW_SUBTRACTION)))
    }
}
