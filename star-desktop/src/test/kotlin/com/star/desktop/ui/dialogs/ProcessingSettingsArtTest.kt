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
        assertEquals(8, FIELD_ART.size)
    }

    @Test
    fun horizonAndKeypointArt() {
        assertEquals(com.star.desktop.ui.components.StarArt.ART_SETTING_HORIZON_EXTENSION, FIELD_ART["Ground horizon extension"])
        assertEquals(com.star.desktop.ui.components.StarArt.ART_SETTING_HORIZON_EXTENSION, FIELD_ART["Sky horizon extension"])
        assertEquals(com.star.desktop.ui.components.StarArt.ART_SETTING_KEYPOINT_SIZE, FIELD_ART["Keypoint detection divisor"])
    }
}
