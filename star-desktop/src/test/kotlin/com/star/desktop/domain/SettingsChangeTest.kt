package com.star.desktop.domain

import com.star.proto.ConfigChangePreview
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class SettingsChangeTest {
    private fun preview(contradicts: Boolean, vararg stages: String) =
        ConfigChangePreview.newBuilder().addAllStaleStages(stages.toList()).setContradictsFinishedWork(contradicts).build()

    @Test fun nothingToWarnAboutUntilTheDaemonSaysSo() {
        assertFalse(SettingsChange.of(null).contradictsFinishedWork)
        assertEquals("ui.process_now", SettingsChange.NONE.processKey)
    }

    @Test fun overFinishedWorkTheButtonIsUpdate() {
        val change = SettingsChange.of(preview(true, "keypoints", "alignment"))
        assertEquals("ui.update", change.processKey)
        assertEquals(listOf("keypoints", "alignment"), change.staleStages)
    }

    @Test fun aStaleChangeWithNothingFinishedStaysProcessNow() {
        assertEquals("ui.process_now", SettingsChange.of(preview(false, "keypoints")).processKey)
    }

    /** Over a live run the button is what makes a change reach the frames the run has not got to, so it works only for a change that contradicts. */
    @Test fun duringARunTheButtonWorksOnlyForAContradiction() {
        assertTrue(SettingsChange.NONE.canProcess(isProcessing = false))
        assertFalse(SettingsChange.NONE.canProcess(isProcessing = true))
        assertTrue(SettingsChange.of(preview(true, "output")).canProcess(isProcessing = true))
        assertTrue(SettingsChange.of(preview(true, "output")).canProcess(isProcessing = false))
    }

    @Test fun theWordsAreInTheCatalogue() {
        com.star.desktop.i18n.Strings.setOverride("en")
        try {
            for (key in listOf("ui.update", "ui.process_now", "ui.already_processed_frames_have_different_settings", "ui.reprocess_already_processed_frames_question")) {
                assertFalse(com.star.desktop.i18n.localized(key) == key, "$key is not in the catalogue")
            }
        } finally {
            com.star.desktop.i18n.Strings.setOverride(null)
        }
    }
}
