package com.star.desktop.ui.initial

import com.star.desktop.ui.components.StarArt
import kotlin.test.Test
import kotlin.test.assertEquals

class DropZoneArtTest {
    @Test
    fun hoverShowsCatchingRobot() {
        assertEquals(StarArt.ART_DROP_HOVER, dropZoneArt(hovering = true))
        assertEquals(StarArt.ART_DROP, dropZoneArt(hovering = false))
    }
}
