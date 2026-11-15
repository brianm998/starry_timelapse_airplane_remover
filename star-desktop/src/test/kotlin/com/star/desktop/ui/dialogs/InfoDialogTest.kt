package com.star.desktop.ui.dialogs

import com.star.desktop.i18n.Strings
import com.star.desktop.i18n.localized
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** The Info dialog's tabs and what they say (macOS `InfoType`). */
class InfoDialogTest {
    @BeforeTest fun english() = Strings.setOverride("en")
    @AfterTest fun systemLanguage() = Strings.setOverride(null)

    @Test fun theTabsAreNamedFromTheCatalogue() {
        assertEquals(listOf("About", "How To", "Detailed"), InfoType.entries.map { localized(it.labelKey) })
    }

    @Test fun theTabNamesAreInEveryLanguage() {
        for (code in Strings.languages.map { it.code }) {
            Strings.setOverride(code)
            try {
                for (type in InfoType.entries) assertFalse(localized(type.labelKey) == type.labelKey, "$code: ${type.labelKey}")
            } finally {
                Strings.setOverride("en")
            }
        }
    }

    /** The detailed tab was a paraphrase that left out what each step shows in edit mode; it is the macOS text now. */
    @Test fun theDetailedTextIsTheMacOSTextWithItsEditModeNotes() {
        val text = InfoType.DETAILED.infoText
        assertTrue(text.startsWith("Star processes each frame of a sequence in this manner:"))
        assertTrue("You can see the star and earth aligned images for each frame and how well is is aligned in edit mode." in text)
        assertTrue("You can see the subtraction image for each frame in edit mode." in text)
        assertTrue("You can see the initial blobs for each frame in edit mode." in text)
        assertTrue("You can see how the many different blob processing steps work for each frame in edit mode." in text)
        assertTrue(text.trimEnd().endsWith("Star is still a work in progress."))
        assertTrue(" - better pixel replacement close to the horizon" in text, "the list under the horizon step")
    }

    @Test fun aboutFromCatalogue() {
        assertEquals(
            listOf("ui.info_about_name", "ui.info_about_purpose", "ui.info_about_license",
                   "ui.info_about_what_it_does", "ui.info_about_video_formats", "ui.info_about_image_formats"),
            ABOUT_KEYS,
        )
        assertEquals("https://github.com/brianm998/starry_timelapse_airplane_remover", STAR_SOURCE_URL)
        assertTrue(localized(ABOUT_KEYS[0]).startsWith("Star is the Starry Timelapse Airplane Remover."))
        val english = ABOUT_KEYS.map { localized(it) }
        for (code in Strings.languages.map { it.code }.filter { it != "en" }) {
            Strings.setOverride(code)
            try {
                ABOUT_KEYS.forEachIndexed { i, key -> assertFalse(localized(key) == english[i], "$code: $key is English") }
            } finally {
                Strings.setOverride("en")
            }
        }
    }

    @Test fun theHowToTextIsThereToo() {
        assertTrue(InfoType.HOW_TO.infoText.startsWith("To get started with Star"))
        assertTrue(InfoType.HOW_TO.infoText.trimEnd().endsWith("The config can be loaded by dropping it onto Star's initial screen."))
    }
}
