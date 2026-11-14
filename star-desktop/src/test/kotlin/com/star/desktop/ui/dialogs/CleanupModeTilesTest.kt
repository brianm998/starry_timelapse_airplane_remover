package com.star.desktop.ui.dialogs

import com.star.desktop.ui.components.StarArt
import com.star.desktop.ui.components.fittedSize
import com.star.proto.CleanMethod
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull

/** The cleanup sheet's tiles: which picture each row shows and the size it is drawn at. */
class CleanupModeTilesTest {
    private fun assertTile(art: StarArt, expected: StarArt, side: Int) {
        assertEquals(expected, art)
        assertNotNull(StarArt::class.java.classLoader.getResource(art.resourcePath), "${art.resourcePath} is missing")
        val (w, h) = art.fittedSize(side)
        assertEquals(side, maxOf(w, h))
    }

    @Test fun modeRowTiles() {
        assertEquals(64, CLEANUP_MODE_TILE)
        assertTile(cleanupTile(CleanMethod.CLEAN_AUTOMATIC), StarArt.ART_MODE_AUTOMATIC, CLEANUP_MODE_TILE)
        assertTile(cleanupTile(CleanMethod.CLEAN_SELECTIVE), StarArt.ART_MODE_SELECTIVE, CLEANUP_MODE_TILE)
    }

    @Test fun autoSelectiveTile() {
        assertEquals(40, CLEANUP_AUTO_SELECTIVE_TILE)
        assertTile(cleanupTile(CleanMethod.CLEAN_AUTOMATIC_TRUE), StarArt.ART_MODE_AUTO_SELECTIVE, CLEANUP_AUTO_SELECTIVE_TILE)
        assertEquals(48, CLEANUP_GROUND_ALIGNMENT_TILE)
        assertTile(CLEANUP_GROUND_ALIGNMENT_ART, StarArt.ART_GROUND_ALIGNMENT, CLEANUP_GROUND_ALIGNMENT_TILE)
    }
}
