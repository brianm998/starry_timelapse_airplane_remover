package com.star.desktop.domain

import com.star.desktop.i18n.Strings
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class WindowTitleTest {
    @BeforeTest fun english() = Strings.setOverride("en")
    @AfterTest fun systemLanguage() = Strings.setOverride(null)

    @Test fun withASequenceOpenTheTitleNamesItsFolder() {
        assertEquals("Star - night-sky-0413", WindowTitle.of("night-sky-0413"))
    }

    @Test fun withNothingOpenItIsTheProductsName() {
        assertEquals("Star", WindowTitle.of(null))
        assertEquals("Star", WindowTitle.of(""))
        assertEquals("Star", WindowTitle.of("  "))
    }

    @Test fun theFolderIsPlacedWhereTheLanguageWantsIt() {
        for (language in Strings.languages) {
            Strings.setOverride(language.code)
            val title = WindowTitle.of("my folder")
            assertTrue("my folder" in title && !title.contains("{0}"), "${language.code}: $title")
        }
    }
}
