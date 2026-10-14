package com.star.desktop.domain

import com.star.proto.BoundingBox
import com.star.proto.OutlierGroup
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

class OutlierHitTest {
    private fun group(id: Int, minX: Int, minY: Int, maxX: Int, maxY: Int, size: Long = 100) = OutlierGroup.newBuilder()
        .setId(id).setSize(size)
        .setBounds(BoundingBox.newBuilder().setMinX(minX).setMinY(minY).setMaxX(maxX).setMaxY(maxY)).build()

    private val outer = group(1, 0, 0, 100, 100)
    private val inner = group(2, 40, 40, 60, 60)

    /** Anywhere in a group's box hits it, not only its pixels. */
    @Test fun aPointInsideABoxHitsItsGroup() {
        assertEquals(1, OutlierHit.smallestBoxContaining(listOf(outer, inner), 10, 10)?.id)
    }

    /** Where boxes overlap the smaller is on top, so the one inside another can still be reached. */
    @Test fun whereBoxesOverlapTheSmallestWins() {
        assertEquals(2, OutlierHit.smallestBoxContaining(listOf(outer, inner), 50, 50)?.id)
        assertEquals(2, OutlierHit.smallestBoxContaining(listOf(inner, outer), 50, 50)?.id)
    }

    @Test fun theBoxEdgesAreInside() {
        assertEquals(2, OutlierHit.smallestBoxContaining(listOf(outer, inner), 40, 60)?.id)
        assertEquals(2, OutlierHit.smallestBoxContaining(listOf(outer, inner), 60, 40)?.id)
        assertNull(OutlierHit.smallestBoxContaining(listOf(outer, inner), 101, 50))
    }

    // arrows: frame 1000 x 500, arrows 14 long and 6 across (width/70 and width/180 would be 14 and 5.5)

    @Test fun theFourArrowsPointInFromJustOutsideTheFrame() {
        val g = group(3, 400, 200, 500, 300)       // centre (450.5, 250.5)
        val (left, top, right, bottom) = OutlierHit.arrowRects(g, 1000f, 500f, 14f, 6f)
        assertTrue(left.contains(-5f, 250f) && !left.contains(5f, 250f), "left arrow lies outside the frame")
        assertTrue(top.contains(450f, -5f) && !top.contains(450f, 5f), "top arrow")
        assertTrue(right.contains(1005f, 250f) && !right.contains(995f, 250f), "right arrow")
        assertTrue(bottom.contains(450f, 505f) && !bottom.contains(450f, 495f), "bottom arrow")
    }

    @Test fun anArrowThatIsShowingCanBeClickedAndOneThatIsNotCannot() {
        val g = group(3, 400, 200, 500, 300)
        assertEquals(3, OutlierHit.arrowGroupAt(listOf(g), -5f, 250f, 1000f, 500f, 14f, 6f) { true }?.id)
        assertNull(OutlierHit.arrowGroupAt(listOf(g), -5f, 250f, 1000f, 500f, 14f, 6f) { false })
        assertNull(OutlierHit.arrowGroupAt(listOf(g), -5f, 100f, 1000f, 500f, 14f, 6f) { true }, "off the arrow's height")
    }

    /** Two groups' arrows at one spot: the smaller group's (the one hardest to reach another way). */
    @Test fun overlappingArrowsGoToTheSmallerGroup() {
        val a = group(1, 400, 200, 500, 300, size = 1000)
        val b = group(2, 410, 205, 490, 295, size = 50)
        assertEquals(2, OutlierHit.arrowGroupAt(listOf(a, b), -5f, 250f, 1000f, 500f, 14f, 6f) { true }?.id)
    }
}
