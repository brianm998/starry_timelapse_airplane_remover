package com.star.desktop.domain

import com.star.proto.BoundingBox
import com.star.proto.Line
import com.star.proto.OutlierGroup
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull

class StreakLineTest {
    private fun group(minX: Int, minY: Int, maxX: Int, maxY: Int, line: Line? = null) = OutlierGroup.newBuilder()
        .setId(1).setSize(100)
        .setBounds(BoundingBox.newBuilder().setMinX(minX).setMinY(minY).setMaxX(maxX).setMaxY(maxY))
        .apply { if (line != null) setLine(line) }
        .build()

    private fun line(theta: Double, rho: Double) = Line.newBuilder().setTheta(theta).setRho(rho).setVotes(10).build()

    /** The two ends, left one first (the order they come out in follows the line's direction, which nothing depends on). */
    private fun ends(s: StreakLine.Segment): List<Pair<Float, Float>> =
        listOf(s.x1 to s.y1, s.x2 to s.y2).sortedWith(compareBy({ it.first }, { it.second }))

    private fun assertPoint(x: Float, y: Float, p: Pair<Float, Float>) {
        assertEquals(x, p.first, 1e-3f, "x")
        assertEquals(y, p.second, 1e-3f, "y")
    }

    /** theta 90° is a line of constant y = rho. */
    @Test fun aHorizontalLineRunsAcrossTheBox() {
        val e = ends(assertNotNull(StreakLine.segment(90.0, 50.0, 100.0, 80.0)))
        assertPoint(0f, 50f, e[0]); assertPoint(100f, 50f, e[1])
    }

    /** theta 0° is a line of constant x = rho. */
    @Test fun aVerticalLineRunsFromTopToBottom() {
        val e = ends(assertNotNull(StreakLine.segment(0.0, 30.0, 100.0, 80.0)))
        assertPoint(30f, 0f, e[0]); assertPoint(30f, 80f, e[1])
    }

    /** x + y = 100 across a 100 x 100 box: corner to corner. */
    @Test fun aDiagonalIsClippedToTheBox() {
        val e = ends(assertNotNull(StreakLine.segment(45.0, 100.0 / Math.sqrt(2.0), 100.0, 100.0)))
        assertPoint(0f, 100f, e[0]); assertPoint(100f, 0f, e[1])
    }

    /** A shallow line leaves through the sides, not the top and bottom: it must stop at the box, not run on to where it meets them. */
    @Test fun aShallowLineStopsAtTheLeftAndRightEdges() {
        // y = 40 + 0.1 x, i.e. -0.1 x + y = 40, divided by its length to be x cos(theta) + y sin(theta) = rho
        val theta = Math.toDegrees(Math.atan2(1.0, -0.1))
        val rho = 40 / Math.sqrt(1.01)
        val e = ends(assertNotNull(StreakLine.segment(theta, rho, 200.0, 100.0)))
        assertPoint(0f, 40f, e[0]); assertPoint(200f, 60f, e[1])
    }

    @Test fun aLineOutsideTheBoxIsNotDrawn() {
        assertNull(StreakLine.segment(90.0, 500.0, 100.0, 100.0))
        assertNull(StreakLine.segment(0.0, -5.0, 100.0, 100.0))
    }

    @Test fun aLineThatOnlyTouchesACornerIsNotDrawn() {
        assertNull(StreakLine.segment(45.0, 0.0, 100.0, 100.0))
    }

    /** The line is measured from the box's own corner, so the segment moves with the group. */
    @Test fun theSegmentIsInImageCoordinates() {
        val s = assertNotNull(StreakLine.segment(group(200, 300, 300, 400, line(90.0, 50.0))))
        val e = ends(s)
        assertPoint(200f, 350f, e[0]); assertPoint(300f, 350f, e[1])
    }

    @Test fun aGroupWithoutALineHasNoSegment() {
        assertNull(StreakLine.segment(group(0, 0, 100, 100)))
    }
}
