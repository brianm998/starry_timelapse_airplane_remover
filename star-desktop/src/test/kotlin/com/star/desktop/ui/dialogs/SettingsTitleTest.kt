package com.star.desktop.ui.dialogs

import com.star.desktop.i18n.Strings
import com.star.desktop.i18n.localized
import java.io.File
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotEquals
import kotlin.test.assertTrue

/** P8: the settings sheet's header is the gui's: the key `ProcessingSettingsView` reads, not the menu item's name. */
class SettingsTitleTest {
    @AfterTest fun reset() = Strings.setOverride(null)

    private fun find(path: String) = listOf(File(path), File("../$path")).first { it.isFile }.readText()

    @Test fun theGuiAndTheDesktopReadTheSameKey() {
        val gui = find("gui/star/ProcessingSettingsView.swift")
        assertTrue("Text(localized(\"$SETTINGS_TITLE_KEY\"))" in gui, "the gui's header moved")
        assertTrue("localized(SETTINGS_TITLE_KEY)" in find("star-desktop/src/main/kotlin/com/star/desktop/ui/dialogs/ProcessingSettingsDialog.kt"))
    }

    @Test fun itIsTranslated() {
        Strings.setOverride("en")
        val english = localized(SETTINGS_TITLE_KEY)
        assertEquals("Choose from the following options to let Star know the best way to process this video.", english)
        Strings.setOverride("de")
        assertNotEquals(english, localized(SETTINGS_TITLE_KEY))
    }
}
