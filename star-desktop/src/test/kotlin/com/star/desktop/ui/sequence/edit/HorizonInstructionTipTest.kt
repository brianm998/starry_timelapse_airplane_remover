package com.star.desktop.ui.sequence.edit

import com.star.desktop.ui.components.StarArt
import kotlin.test.Test
import kotlin.test.assertEquals

class HorizonInstructionTipTest {
    @Test
    fun diagramsForStaticAndMoving() {
        val three = listOf(StarArt.ART_PAINT_BRUSH, StarArt.ART_PAINT_FILL, StarArt.ART_PAINT_TOUCH_UP)
        assertEquals(three, horizonPainterDiagrams(isMoving = false))
        assertEquals(three + StarArt.ART_PAINT_MOVING, horizonPainterDiagrams(isMoving = true))
    }
}
