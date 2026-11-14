package com.star.desktop.ui.components

import java.awt.image.BufferedImage
import javax.imageio.ImageIO
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

/** The art set (art/export.py): every slot is a resource, and cut-out art has no painted background left. */
class StarArtTest {
    private fun load(art: StarArt): BufferedImage {
        val stream = StarArt::class.java.classLoader.getResourceAsStream(art.resourcePath)
        assertNotNull(stream, "${art.resourcePath} is missing from the resources")
        return stream.use { ImageIO.read(it) }
    }

    @Test
    fun everySlotLoads() {
        assertEquals(62, StarArt.entries.size)
        for (art in StarArt.entries) {
            val img = load(art)
            // The resource is the 2x image, or the largest the master allows (never upscaled).
            assertTrue(img.width > 0 && img.height > 0, art.slot)
            assertTrue(img.width >= art.width && img.height >= art.height, "${art.slot} is smaller than its display size")
            assertTrue(img.width <= 2 * art.width + 2 && img.height <= 2 * art.height + 2 || art.kind == ArtKind.SCENE, art.slot)
        }
    }

    @Test
    fun cutoutsAndTilesHaveTransparentCorners() {
        for (art in StarArt.entries.filter { it.kind != ArtKind.SCENE }) {
            val img = load(art)
            assertTrue(img.colorModel.hasAlpha(), "${art.slot} has no alpha channel")
            val w = img.width
            val h = img.height
            val corners = listOf(0 to 0, w - 1 to 0, 0 to h - 1, w - 1 to h - 1)
            if (art.kind == ArtKind.TILE || art.slot in CHECKER_CLEANED) {
                for ((x, y) in corners) {
                    // export.py's has_real_alpha: a master's own alpha counts when its corners are under 16, and is kept as is
                    // (art_format_tiff16's corners are 1).
                    val a = img.getRGB(x, y) ushr 24
                    assertTrue(a < 16, "${art.slot} corner ($x, $y) is not transparent (alpha $a)")
                }
            }
            if (art.slot in CHECKER_CLEANED) {
                // No light fringe: partly transparent pixels must not be near-white (the painted checkerboard's colour).
                // Tiles are matted from black, so a light edge on them is the tile's own paint (art_step_render: 38%).
                var edge = 0
                var light = 0
                for (y in 0 until h) for (x in 0 until w) {
                    val argb = img.getRGB(x, y)
                    val a = argb ushr 24
                    if (a in 1..254) {
                        edge++
                        val lo = minOf((argb shr 16) and 255, (argb shr 8) and 255, argb and 255)
                        if (lo > 225) light++
                    }
                }
                val allowed = edge * LIGHT_EDGE_SHARE
                assertTrue(light <= allowed, "${art.slot}: $light of $edge edge pixels are near-white")
            }
        }
    }

    private companion object {
        /**
         * Share of partly transparent pixels allowed to be near-white. The robot's armour is white-lavender, so real paint on
         * the soft edge reads as light: the checked slots measure 6-20% (art_waiting 19%, art_horizon_auto 15%) and export.py's
         * erode/tolerance do not move them. A leftover checkerboard fringe would be most of the edge, far above this.
         */
        const val LIGHT_EDGE_SHARE = 0.25

        /** Slots whose master was an opaque picture with a painted checkerboard (cleaned by export.py). */
        val CHECKER_CLEANED = setOf("art_horizon_auto", "art_process_gear", "art_waiting")
    }
}
