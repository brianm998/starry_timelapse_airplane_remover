package com.star.desktop.ui.dialogs

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class ProcessingSettingsArtTest {
    @Test
    fun everyArtLabelHasHelp() {
        for (label in FIELD_ART.keys) {
            assertTrue(FIELD_HELP[label].orEmpty().isNotEmpty(), "diagram for \"$label\", which has no help text")
        }
        assertEquals(5, FIELD_ART.size)
    }
}
