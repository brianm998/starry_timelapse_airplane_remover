package com.star.desktop.ui.sequence.edit

import com.star.desktop.data.OutlierRepository
import com.star.proto.BoundingBox
import com.star.proto.OutlierGroup
import com.star.proto.RemoveReason
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotEquals
import kotlin.test.assertTrue

class OutlierOverlayTest {
    private fun group(id: Int, minX: Int, minY: Int, maxX: Int, maxY: Int, size: Long, reason: RemoveReason = RemoveReason.RR_UNDECIDED) =
        OutlierGroup.newBuilder().setId(id).setSize(size).setShouldRemove(reason)
            .setBounds(BoundingBox.newBuilder().setMinX(minX).setMinY(minY).setMaxX(maxX).setMaxY(maxY)).build()

    /** A 10 x 10 label map with group 1 at x 0..3, y 0..3 and group 2 (one pixel) at (8, 8). */
    private fun labels(): OutlierRepository.LabelMap {
        val ids = ShortArray(100)
        for (y in 0..3) for (x in 0..3) ids[y * 10 + x] = 1
        ids[8 * 10 + 8] = 2
        return OutlierRepository.LabelMap(10, 10, ids)
    }

    private val large = group(1, 0, 0, 3, 3, size = 16)   // 16 is not > 40: make "large" explicitly below where it matters
    private val big = group(1, 0, 0, 3, 3, size = 500)
    private val small = group(2, 8, 8, 8, 8, size = 1)

    @Test fun onlyGroupPixelsAreColouredAndTheRestIsTransparent() {
        val px = OutlierOverlay.pixels(labels(), listOf(big, small), emptyMap(), selected = null)
        assertEquals(10, px.width)
        assertEquals(10, px.height)
        assertNotEquals(0, px.argb[0], "a pixel of group 1 is transparent")
        assertEquals(0, px.argb[5 * 10 + 5], "a pixel of no group is not transparent")
        assertNotEquals(0, px.argb[8 * 10 + 8], "the small group's pixel is missing")
    }

    @Test fun aLargeGroupIsRedWhenRemovedGreenWhenKeptAndBlueWhenUndecided() {
        fun at0(reason: RemoveReason) = OutlierOverlay.pixels(labels(), listOf(big), mapOf(1 to reason), null).argb[0]
        val remove = at0(RemoveReason.RR_USER_REMOVE)
        val keep = at0(RemoveReason.RR_USER_KEEP)
        val undecided = at0(RemoveReason.RR_UNDECIDED)
        assertTrue((remove shr 16 and 0xFF) > 200 && (remove and 0xFF) < 100, "remove should be red: ${remove.toString(16)}")
        assertTrue((keep shr 8 and 0xFF) > 150 && (keep shr 16 and 0xFF) < 100, "keep should be green: ${keep.toString(16)}")
        assertTrue((undecided and 0xFF) > 200 && (undecided shr 16 and 0xFF) < 50, "undecided should be blue: ${undecided.toString(16)}")
        assertEquals(setOf(remove, keep, undecided).size, 3)
    }

    @Test fun theSelectedGroupIsOrange() {
        val sel = OutlierOverlay.pixels(labels(), listOf(big), mapOf(1 to RemoveReason.RR_USER_KEEP), selected = 1).argb[0]
        assertTrue((sel shr 16 and 0xFF) > 200 && (sel shr 8 and 0xFF) in 100..200 && (sel and 0xFF) < 50, sel.toString(16))
    }

    /** Groups of 40 pixels or fewer are two combined masks: red if they will be painted out, otherwise green, undecided included. */
    @Test fun aSmallGroupIsRedOrGreenNeverBlue() {
        fun small(reason: RemoveReason) = OutlierOverlay.pixels(labels(), listOf(small), mapOf(2 to reason), null).argb[8 * 10 + 8]
        val red = small(RemoveReason.RR_CLASSIFIER_REMOVE)
        val green = small(RemoveReason.RR_UNDECIDED)
        assertEquals(small(RemoveReason.RR_USER_KEEP), green)
        assertTrue((red shr 16 and 0xFF) > 200)
        assertTrue((green shr 8 and 0xFF) > 150 && (green and 0xFF) < 100)
    }

    @Test fun onlyGroupsOverFortyPixelsAreSeparateThingsInTheUi() {
        assertTrue(OutlierOverlay.isLarge(group(1, 0, 0, 1, 1, size = 41)))
        assertEquals(false, OutlierOverlay.isLarge(group(1, 0, 0, 1, 1, size = 40)))
        assertEquals(false, OutlierOverlay.isLarge(large.toBuilder().setSize(1).build()))
    }

    /** A wide frame is drawn on a smaller overlay: its size is bounded, and a group's pixels still land on it. */
    @Test fun aWideFrameGetsABoundedOverlay() {
        val w = 8192
        val h = 100
        val ids = ShortArray(w * h)
        for (y in 10..20) for (x in 4000..4100) ids[y * w + x] = 7
        val g = group(7, 4000, 10, 4100, 20, size = 1111)
        val px = OutlierOverlay.pixels(OutlierRepository.LabelMap(w, h, ids), listOf(g), emptyMap(), null)
        assertEquals(OutlierOverlay.MAX_WIDTH, px.width)
        assertTrue(px.argb.any { it != 0 }, "the group disappeared in the scaling")
    }
}
