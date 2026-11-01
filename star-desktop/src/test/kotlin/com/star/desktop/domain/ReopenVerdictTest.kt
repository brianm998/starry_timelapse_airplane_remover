package com.star.desktop.domain

import com.star.proto.SequenceProgress
import com.star.proto.StepCount
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class ReopenVerdictTest {
    private fun progress(complete: Boolean = false, untouched: Boolean = false, rebuild: Boolean = false) =
        SequenceProgress.newBuilder().setFrameCount(10).setIsComplete(complete).setIsUntouched(untouched).setNeedsRebuild(rebuild).build()

    @Test fun aSequenceWithEveryFrameWrittenOffersTheVideo() {
        val verdict = ReopenVerdict.of(progress(complete = true))
        assertEquals(ReopenVerdict.COMPLETE, verdict)
        assertTrue(verdict.rendersVideo)
        assertEquals("ui.render_video", verdict.actionKey)
    }

    @Test fun aSequenceNothingWasDoneToOffersToStart() {
        val verdict = ReopenVerdict.of(progress(untouched = true))
        assertEquals(ReopenVerdict.UNTOUCHED, verdict)
        assertFalse(verdict.rendersVideo, "a render of frames that are not there would be a video with holes in it")
        assertEquals("ui.start_processing", verdict.actionKey)
    }

    @Test fun aPartlyProcessedSequenceOffersToFinish() {
        val verdict = ReopenVerdict.of(progress())
        assertEquals(ReopenVerdict.PARTIAL, verdict)
        assertFalse(verdict.rendersVideo)
        assertEquals("ui.finish_processing", verdict.actionKey)
    }

    /** Every frame written, but made by an older star or other settings: the daemon reports it not complete, and the panel offers the run, saying why. */
    @Test fun aSequenceToBeRebuiltOffersToFinishAndSaysWhy() {
        val verdict = ReopenVerdict.of(progress(rebuild = true))
        assertEquals(ReopenVerdict.REBUILD, verdict)
        assertFalse(verdict.rendersVideo)
        assertEquals("ui.finish_processing", verdict.actionKey)
        assertEquals("ui.this_sequence_needs_rebuilding", verdict.statusKey)
    }

    /** Complete wins: the daemon never says both, but a finished sequence must not be offered a start whichever way the flags fall. */
    @Test fun completeOutranksUntouched() {
        assertEquals(ReopenVerdict.COMPLETE, ReopenVerdict.of(progress(complete = true, untouched = true)))
    }

    /** Settings sits immediately left of the action in every state (macOS `footerActions`), and the action stays the rightmost button. */
    @Test fun everyVerdictPutsSettingsJustLeftOfTheAction() {
        for (v in ReopenVerdict.values()) {
            assertEquals(listOf(SequenceProgressButton.CLOSE, SequenceProgressButton.SETTINGS, SequenceProgressButton.ACTION), v.footer, "$v")
        }
        assertEquals("sequenceprogress.settings", SequenceProgressButton.SETTINGS.testTag)
        assertEquals("sequenceprogress.close", SequenceProgressButton.CLOSE.testTag)
    }

    @Test fun everyWordingIsInTheCatalogue() {
        com.star.desktop.i18n.Strings.setOverride("en")
        try {
            for (v in ReopenVerdict.values()) {
                for (key in listOf(v.statusKey, v.actionKey, v.actionHelpKey)) {
                    assertFalse(com.star.desktop.i18n.localized(key) == key, "$key is not in the catalogue")
                }
            }
        } finally {
            com.star.desktop.i18n.Strings.setOverride(null)
        }
    }

    @Test fun theSurveyRowsAreTheProcessingScreensRows() {
        val p = SequenceProgress.newBuilder()
            .addSteps(StepCount.newBuilder().setType("horizon").setQueued(2).setAlreadyDone(8))
            .addSteps(StepCount.newBuilder().setType("merge").setQueued(10))
            .build()
        val rows = StepRow.of(p.stepsList)
        assertEquals(listOf("horizon", "merge"), rows.map { it.type })
        assertEquals(0.8f, rows[0].doneFraction)
        assertEquals(0f, rows[1].doneFraction)
    }
}
