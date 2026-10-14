package com.star.desktop.ui.sequence.edit

import com.star.desktop.data.OutlierRepository
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class TrashOverlayTest {
    private fun mask(w: Int, h: Int, vararg set: Pair<Int, Int>): OutlierRepository.Mask {
        val bytes = ByteArray(w * h)
        set.forEach { (x, y) -> bytes[y * w + x] = 1 }
        return OutlierRepository.Mask(w, h, bytes)
    }

    @Test fun onlyTrashPixelsAreDrawnAndInYellowAtTheOpacity() {
        val px = TrashOverlay.pixels(mask(4, 4, 1 to 1), opacity = 0.5f)
        assertEquals(0, px.argb[0], "a pixel that is not trash is not transparent")
        val c = px.argb[1 * 4 + 1]
        assertEquals(127, c ushr 24, "the opacity is the alpha")
        assertTrue((c shr 16 and 0xFF) > 200 && (c shr 8 and 0xFF) > 150 && (c and 0xFF) < 50, "yellow: ${c.toString(16)}")
    }

    @Test fun opacityIsClamped() {
        assertEquals(255, TrashOverlay.pixels(mask(2, 2, 0 to 0), 3f).argb[0] ushr 24)
        assertEquals(0, TrashOverlay.pixels(mask(2, 2, 0 to 0), -1f).argb[0] ushr 24)
    }

    @Test fun aWideFrameIsDrawnOnABoundedOverlayAndTheTrashSurvivesTheScaling() {
        val w = 6000
        val m = mask(w, 20, 3000 to 10)
        val px = TrashOverlay.pixels(m, 0.7f)
        assertEquals(OutlierOverlay.MAX_WIDTH, px.width)
        assertTrue(px.argb.any { it != 0 })
    }
}
