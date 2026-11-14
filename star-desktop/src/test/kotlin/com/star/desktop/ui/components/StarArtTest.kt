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
                    assertEquals(0, (img.getRGB(x, y) ushr 24), "${art.slot} corner ($x, $y) is not transparent")
                }
            }
            if (art.slot !in LIGHT_EDGED && (art.slot in CHECKER_CLEANED || art.kind == ArtKind.TILE)) {
                // No light fringe: partly transparent pixels must not be near-white (the painted checkerboard's colour).
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
                assertTrue(light <= edge / 20, "${art.slot}: $light of $edge edge pixels are near-white")
            }
        }
    }

    private companion object {
        /** Slots whose master was an opaque picture with a painted checkerboard (cleaned by export.py). */
        val CHECKER_CLEANED = setOf("art_horizon_auto", "art_process_gear", "art_waiting")

        /** Cut-outs whose own outline is pale (about 15% of art_horizon_auto's edge pixels), so the fringe count cannot tell art from leftover checker; the corner check still applies. */
        val LIGHT_EDGED = setOf("art_horizon_auto")
    }
}
