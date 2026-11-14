package com.star.desktop.ui.initial

import androidx.compose.ui.unit.dp
import com.star.desktop.ui.components.StarArt
import com.star.desktop.ui.components.fittedSize
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** The Welcome screen's pictures: a tile per button, a greeter that steps aside in small windows, a banner that keeps the robot and dog. */
class WelcomeArtTest {
    @Test
    fun welcomeButtonTiles() {
        assertEquals(StarArt.ART_TILE_LOAD_VIDEO, tileArt(OpenKind.VIDEO))
        assertEquals(StarArt.ART_TILE_LOAD_SEQUENCE, tileArt(OpenKind.SEQUENCE))
        assertEquals(StarArt.ART_TILE_LOAD_CONFIG, tileArt(OpenKind.CONFIG))
        for (art in listOf(StarArt.ART_TILE_LOAD_VIDEO, StarArt.ART_TILE_LOAD_SEQUENCE, StarArt.ART_TILE_LOAD_CONFIG, StarArt.ART_TILE_LEARN)) {
            assertEquals(48 to 48, art.fittedSize(null))
        }
        assertFalse(WelcomeArt.greeterShown(700.dp, 500.dp))
        assertFalse(WelcomeArt.greeterShown(1280.dp, 500.dp))
        assertTrue(WelcomeArt.greeterShown(1280.dp, 800.dp))
        assertTrue(WelcomeArt.BANNER_TOP <= 0.35 && WelcomeArt.BANNER_BOTTOM >= 0.92)
        assertEquals(294.dp, WelcomeArt.bannerHeight)
    }
}
