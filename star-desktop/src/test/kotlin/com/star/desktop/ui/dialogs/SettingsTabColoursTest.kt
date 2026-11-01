package com.star.desktop.ui.dialogs

import androidx.compose.ui.graphics.Color
import com.star.desktop.ui.components.starPickerTextColor
import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/** The settings sheet's tab titles: black on the selected pill, white on the grey track otherwise (the gui's `SettingsTabTitleColorTests`). */
class SettingsTabColoursTest {
    private fun find(path: String) = listOf(File(path), File("../$path")).first { it.isFile }.readText()

    @Test fun testSettingsTabsUseBlackWhenSelectedAndWhiteWhenNot() {
        assertEquals(Color.White, SETTINGS_TAB_UNSELECTED_TEXT)
        assertEquals(Color.Black, starPickerTextColor(selected = true, usable = true, unselectedText = SETTINGS_TAB_UNSELECTED_TEXT))
        assertEquals(Color.White, starPickerTextColor(selected = false, usable = true, unselectedText = SETTINGS_TAB_UNSELECTED_TEXT))
        val dialog = find("star-desktop/src/main/kotlin/com/star/desktop/ui/dialogs/ProcessingSettingsDialog.kt")
        assertTrue("unselectedText = SETTINGS_TAB_UNSELECTED_TEXT" in dialog, "the tab strip does not pass the white")
    }
}
