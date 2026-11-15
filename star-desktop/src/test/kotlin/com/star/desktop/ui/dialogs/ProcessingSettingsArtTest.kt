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
        assertEquals(9, FIELD_ART.size)
    }

    @Test
    fun horizonAndKeypointArt() {
        assertEquals(com.star.desktop.ui.components.StarArt.ART_SETTING_HORIZON_EXTENSION, FIELD_ART["Ground horizon extension"])
        assertEquals(com.star.desktop.ui.components.StarArt.ART_SETTING_HORIZON_EXTENSION, FIELD_ART["Sky horizon extension"])
        assertEquals(com.star.desktop.ui.components.StarArt.ART_SETTING_KEYPOINT_SIZE, FIELD_ART["Keypoint detection divisor"])
    }

    @Test
    fun choiceArt() {
        assertEquals(com.star.desktop.ui.components.StarArt.ART_SKY_AND_GROUND, sceneArt(true))
        assertEquals(com.star.desktop.ui.components.StarArt.ART_SKY_ONLY, sceneArt(false))
        assertEquals(com.star.desktop.ui.components.StarArt.ART_CAMERA_STATIC, cameraArt(false))
        assertEquals(com.star.desktop.ui.components.StarArt.ART_CAMERA_MOVING, cameraArt(true))
        assertEquals(com.star.desktop.ui.components.StarArt.ART_MODE_AUTO_SELECTIVE, autoPreservationArt(true))
        assertEquals(null, autoPreservationArt(false))
        assertEquals(com.star.desktop.ui.components.StarArt.ART_GROUND_ALIGNMENT, FIELD_ART["Allow earth alignment"])
    }
}
