package com.star.desktop.data

import kotlinx.coroutines.runBlocking
import java.awt.image.BufferedImage
import java.io.File
import javax.imageio.ImageIO
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull

/** The label map the edit view hit-tests against: one unsigned 16-bit group id per pixel. */
class LabelMapTest {
    private val repo = OutlierRepository { null }

    /** A 16-bit gray PNG like the one `Frame.GetOutlierLabelImage` writes, with these ids at these pixels. */
    private fun labelPng(w: Int, h: Int, ids: Map<Pair<Int, Int>, Int>): File {
        val img = BufferedImage(w, h, BufferedImage.TYPE_USHORT_GRAY)
        ids.forEach { (xy, id) -> img.raster.setSample(xy.first, xy.second, 0, id) }
        val f = File.createTempFile("labels", ".png")
        f.deleteOnExit()
        ImageIO.write(img, "png", f)
        return f
    }

    @Test fun everyPixelKeepsItsId() = runBlocking {
        val f = labelPng(5, 4, mapOf((0 to 0) to 1, (4 to 3) to 7, (2 to 1) to 300))
        val map = assertNotNull(repo.loadLabelMap(f.path))
        assertEquals(1, map.idAt(0, 0))
        assertEquals(300, map.idAt(2, 1))
        assertEquals(7, map.idAt(4, 3))
        assertEquals(0, map.idAt(1, 1), "a pixel in no group")
    }

    /** Ids above 32767 are negative as a short: they must come back as the unsigned id the daemon sent. */
    @Test fun idsAboveTheSignedRangeAreNotNegative() = runBlocking {
        val f = labelPng(3, 3, mapOf((1 to 1) to 40_000, (2 to 2) to 65_535))
        val map = assertNotNull(repo.loadLabelMap(f.path))
        assertEquals(40_000, map.idAt(1, 1))
        assertEquals(65_535, map.idAt(2, 2))
    }

    @Test fun outsideTheImageIsNoGroup() = runBlocking {
        val map = assertNotNull(repo.loadLabelMap(labelPng(2, 2, mapOf((0 to 0) to 5)).path))
        assertEquals(0, map.idAt(-1, 0))
        assertEquals(0, map.idAt(0, 2))
        assertEquals(0, map.idAt(2, 0))
    }

    /** One short a pixel (two bytes, not four): a full-resolution frame was ~170 MB as an IntArray. */
    @Test fun aPixelIsStoredInAShort() = runBlocking {
        val map = assertNotNull(repo.loadLabelMap(labelPng(10, 10, emptyMap()).path))
        val ids: ShortArray = map.ids
        assertEquals(100, ids.size)
    }
}
