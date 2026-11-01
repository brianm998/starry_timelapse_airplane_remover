package com.star.desktop.ui.components

import androidx.compose.ui.graphics.Color
import kotlin.test.Test
import kotlin.test.assertEquals

/** The pickers that do not ask for another colour (mode and view pickers) keep their dark unselected text. */
class StarPickerColourTest {
    @Test fun testDefaultUnselectedTextIsUnchanged() {
        assertEquals(Color(0.12f, 0.12f, 0.12f), STAR_PICKER_DEFAULT_UNSELECTED_TEXT)
        assertEquals(Color.Black, starPickerTextColor(selected = true, usable = true))
        assertEquals(STAR_PICKER_DEFAULT_UNSELECTED_TEXT, starPickerTextColor(selected = false, usable = true))
        assertEquals(Color.Gray, starPickerTextColor(selected = false, usable = false))
        assertEquals(Color.Gray, starPickerTextColor(selected = true, usable = false))
    }
}
