package com.star.desktop.domain

import com.star.desktop.ui.components.StarArt
import com.star.desktop.ui.components.fittedSize
import com.star.proto.SequenceProgress
import kotlin.test.Test
import kotlin.test.assertEquals

class ReopenVerdictArtTest {
    private fun progress(complete: Boolean = false, untouched: Boolean = false, rebuild: Boolean = false) =
        SequenceProgress.newBuilder().setFrameCount(10).setIsComplete(complete).setIsUntouched(untouched).setNeedsRebuild(rebuild).build()

    @Test fun verdictArt() {
        assertEquals(StarArt.ART_DONE, ReopenVerdict.of(progress(complete = true)).art)
        assertEquals(StarArt.ART_REBUILDING, ReopenVerdict.of(progress(rebuild = true)).art)
        assertEquals(StarArt.ART_REVIEW, ReopenVerdict.of(progress(untouched = true)).art)
        assertEquals(StarArt.ART_REVIEW, ReopenVerdict.of(progress()).art)
    }

    @Test fun fittingKeepsTheAspect() {
        assertEquals(StarArt.ART_DONE.width to StarArt.ART_DONE.height, StarArt.ART_DONE.fittedSize(null))
        assertEquals(62 to 64, StarArt.ART_DONE.fittedSize(64))
        assertEquals(96 to 84, StarArt.ART_RENDERING.fittedSize(96))
    }
}
