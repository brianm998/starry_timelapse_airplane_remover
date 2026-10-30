package com.star.desktop.ui.sequence

import com.star.desktop.i18n.Strings
import com.star.desktop.i18n.localized
import com.star.proto.FrameViewMode
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals

/** Q8: the mode and view pickers at the bottom left say what the gui's say, in the user's language, and offer the same two images. */
class ModePickersTest {
    @BeforeTest fun english() = Strings.setOverride("en")
    @AfterTest fun systemLanguage() = Strings.setOverride(null)

    @Test fun theViewPickerOffersTheOriginalAndTheFinalFrameAndNothingElse() {
        assertEquals(listOf(FrameViewMode.VIEW_ORIGINAL, FrameViewMode.VIEW_PROCESSED), VIEW_PICKER_MODES)
    }

    @Test fun theViewPickersLabelsAreTheCataloguesInEveryLanguage() {
        assertEquals("Original", viewPickerLabel(FrameViewMode.VIEW_ORIGINAL))
        assertEquals("Processed", viewPickerLabel(FrameViewMode.VIEW_PROCESSED))
        Strings.setOverride("de")
        assertEquals("Bearbeitet", viewPickerLabel(FrameViewMode.VIEW_PROCESSED))
    }

    @Test fun theSentenceAroundThePickersAndTheHelpAreTranslated() {
        val keys = listOf("ui.with", "ui.frames", "ui.interaction_mode_help")
        val english = keys.map { localized(it) }
        for (code in Strings.languages.map { it.code }.filter { it != "en" }) {
            Strings.setOverride(code)
            for ((key, inEnglish) in keys.zip(english)) {
                assertFalse(localized(key) == key, "$code: $key is missing")
                if (key == "ui.interaction_mode_help") assertNotEquals(inEnglish, localized(key), "$code: $key is English")
            }
        }
    }
}
