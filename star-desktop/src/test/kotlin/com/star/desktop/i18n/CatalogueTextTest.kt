package com.star.desktop.i18n

import com.google.gson.Gson
import com.google.gson.reflect.TypeToken
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** What the catalogue's text looks like when it reaches the screen (H6). */
class CatalogueTextTest {
    @BeforeTest fun english() = Strings.setOverride("en")
    @AfterTest fun systemLanguage() = Strings.setOverride(null)

    private fun table(code: String): Map<String, String> =
        CatalogueTextTest::class.java.getResourceAsStream("/i18n/$code.json")!!.bufferedReader().use {
            Gson().fromJson(it, object : TypeToken<Map<String, String>>() {}.type)
        }

    /** The drop zone showed a `\n` of its own: the entry was stored with the backslash escaped, and the text is not unescaped after the JSON is read. */
    @Test fun theDropZoneBreaksItsLineWithARealLineBreak() {
        for (language in Strings.languages) {
            Strings.setOverride(language.code)
            val text = localized("ui.drop_an_image_sequence_folder_video_or")
            assertTrue('\n' in text, "${language.code}: no line break in: $text")
            assertFalse('\\' in text, "${language.code}: a backslash is shown: $text")
        }
    }

    /** No entry shows an escape as text. */
    @Test fun noEntryHoldsAnEscapeThatWouldBeShownAsText() {
        for (language in Strings.languages) {
            for ((key, value) in table(language.code)) {
                assertFalse("\\n" in value || "\\t" in value, "${language.code}: $key shows a backslash escape: $value")
            }
        }
    }
}
