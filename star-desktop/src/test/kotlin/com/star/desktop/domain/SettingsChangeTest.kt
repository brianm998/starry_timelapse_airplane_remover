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

    /** Over a live run the button is what makes a change reach the frames the run has not got to, so only a change that contradicts keeps it a button that acts. */
    @Test fun duringARunTheButtonShowsProgressUnlessThereIsAContradiction() {
        assertFalse(SettingsChange.NONE.showsProgress(isProcessing = false))
        assertTrue(SettingsChange.NONE.showsProgress(isProcessing = true))
        assertTrue(SettingsChange.of(preview(false, "keypoints")).showsProgress(isProcessing = true))
        assertFalse(SettingsChange.of(preview(true, "output")).showsProgress(isProcessing = true))
        assertFalse(SettingsChange.of(preview(true, "output")).showsProgress(isProcessing = false))
    }

    @Test fun theButtonSaysWhatItDoes() {
        assertEquals("ui.process_now", SettingsChange.NONE.buttonKey(isProcessing = false))
        assertEquals("ui.show_progress", SettingsChange.NONE.buttonKey(isProcessing = true))
        assertEquals("ui.update", SettingsChange.of(preview(true, "output")).buttonKey(isProcessing = true))
        assertEquals("ui.update", SettingsChange.of(preview(true, "output")).buttonKey(isProcessing = false))
    }

    @Test fun theWordsAreInTheCatalogue() {
        com.star.desktop.i18n.Strings.setOverride("en")
        try {
            for (key in listOf("ui.update", "ui.process_now", "ui.show_progress", "ui.already_processed_frames_have_different_settings", "ui.reprocess_already_processed_frames_question")) {
                assertFalse(com.star.desktop.i18n.localized(key) == key, "$key is not in the catalogue")
            }
        } finally {
            com.star.desktop.i18n.Strings.setOverride(null)
        }
    }
}
