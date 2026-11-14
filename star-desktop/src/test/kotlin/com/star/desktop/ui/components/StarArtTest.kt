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
            val checked = art.kind == ArtKind.TILE || art.slot in CHECKER_CLEANED
            if (checked) {
                val allowedAlpha = CORNER_ALPHA_EXCEPTIONS[art.slot] ?: 0
                for ((x, y) in corners) {
                    val alpha = img.getRGB(x, y) ushr 24
                    assertTrue(alpha <= allowedAlpha, "${art.slot} corner ($x, $y) is not transparent (alpha $alpha)")
                }
            }
            if (checked) {
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
                val allowed = edge * ((LIGHT_EDGE_BASELINE[art.slot] ?: 0.0) + LIGHT_EDGE_MARGIN)
                assertTrue(light <= allowed, "${art.slot}: $light of $edge edge pixels are near-white")
            }
        }
    }

    private companion object {
        /** Every checked slot may have this share of its partly transparent pixels near-white (a clean cut has almost none)... */
        const val LIGHT_EDGE_MARGIN = 0.05

        /**
         * ...plus the share measured for the slots whose real paint is light on the soft edge (white-lavender armour, white
         * step glyphs). Measured with art/export.py's output; a leftover checkerboard fringe would add to these, so each
         * slot is held to its own value. Update a value only when the art itself is replaced.
         */
        val LIGHT_EDGE_BASELINE = mapOf(
            "art_horizon_auto" to 0.15,
            "art_process_gear" to 0.16,
            "art_waiting" to 0.20,
            "art_mode_selective" to 0.06,
            "art_step_align" to 0.27,
            "art_step_horizon" to 0.15,
            "art_step_merge" to 0.17,
            "art_step_render" to 0.38,
            "art_step_review" to 0.20,
        )

        /** art_format_tiff16's soft-edge blur leaves alpha 1 of 255 in its four corners: invisible, and only this slot. */
        val CORNER_ALPHA_EXCEPTIONS = mapOf("art_format_tiff16" to 1)

        /** Slots whose master was an opaque picture with a painted checkerboard (cleaned by export.py). */
        val CHECKER_CLEANED = setOf("art_horizon_auto", "art_process_gear", "art_waiting")
    }
}
