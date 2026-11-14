package com.star.desktop.ui.dialogs

import com.star.desktop.ui.components.StarArt
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class SpeedSharpnessArtTest {
    @Test
    fun presetTiles() {
        assertEquals(StarArt.ART_PRESET_BEST_QUALITY, presetArt(1.0))
        assertEquals(StarArt.ART_PRESET_BEST_BALANCE, presetArt(1.5))
        assertEquals(StarArt.ART_PRESET_FASTEST, presetArt(2.0))
        assertNull(presetArt(3.0))
        assertNull(presetArt(1.25))
    }
}
