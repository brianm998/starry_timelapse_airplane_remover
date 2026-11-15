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

    @Test fun howToSteps() {
        assertEquals(
            listOf("art_howto_import", "art_howto_questions", "art_howto_process", "art_review", "art_rendering"),
            HOW_TO_STEPS.map { it.art.slot },
        )
        val names = listOf("import", "questions", "process", "review", "render")
        assertEquals(names.map { "ui.info_how_to_${it}_title" }, HOW_TO_STEPS.map { it.titleKey })
        assertEquals(names.map { "ui.info_how_to_${it}_body" }, HOW_TO_STEPS.map { it.bodyKey })
        assertEquals(
            listOf(listOf("ui.load_video", "ui.load_image_sequence"), listOf("ui.processing_settings"),
                   listOf("ui.start_processing"), emptyList(), listOf("ui.render_video", "ui.load_config")),
            HOW_TO_STEPS.map { it.placeholderKeys },
        )
        for (code in listOf("en", "de")) {
            Strings.setOverride(code)
            try {
                for (step in HOW_TO_STEPS) {
                    val raw = localized(step.bodyKey)
                    assertEquals(step.placeholderKeys.size, (0..4).count { "{$it}" in raw }, "$code ${step.bodyKey}")
                    assertFalse("{" in step.body, "$code ${step.bodyKey}")
                }
            } finally {
                Strings.setOverride("en")
            }
        }
        assertEquals("Open your footage", HOW_TO_STEPS[0].heading)
        assertTrue(HOW_TO_STEPS[0].body.startsWith("Click Load Video to open"))
    }
}
