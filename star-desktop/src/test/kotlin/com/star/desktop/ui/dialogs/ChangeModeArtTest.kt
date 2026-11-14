package com.star.desktop.ui.dialogs

import com.star.desktop.domain.HighLevelClean
import com.star.desktop.ui.components.StarArt
import kotlin.test.Test
import kotlin.test.assertEquals

class ChangeModeArtTest {
    @Test
    fun cleanMethodTiles() {
        assertEquals(StarArt.ART_CHANGE_MODE_AUTOMATIC, cleanArt(HighLevelClean.AUTOMATIC))
        assertEquals(StarArt.ART_CHANGE_MODE_SELECTIVE, cleanArt(HighLevelClean.SELECTIVE))
        assertEquals(StarArt.ART_CHANGE_MODE_DIRTY, cleanArt(HighLevelClean.DIRTY))
    }
}
