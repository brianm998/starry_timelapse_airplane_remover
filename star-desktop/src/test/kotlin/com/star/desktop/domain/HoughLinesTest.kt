package com.star.desktop.domain

import com.star.desktop.domain.HoughLines.Column
import com.star.desktop.domain.HoughLines.Sort
import com.star.proto.Line
import com.star.proto.LineCandidate
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class HoughLinesTest {
    private fun candidate(theta: Double, rho: Double, intensity: Double = 0.0, pixel: Double = 0.0, votes: Int = 0, border: Int = 0) =
        LineCandidate.newBuilder()
            .setLine(Line.newBuilder().setTheta(theta).setRho(rho).setVotes(votes))
            .setIntensityScore(intensity).setPixelScore(pixel).setBorder(border).build()

    private val a = candidate(10.0, 5.0, intensity = 0.9, pixel = 3.0, votes = 40, border = 0)
    private val b = candidate(100.0, -2.0, intensity = 0.2, pixel = 8.0, votes = 66, border = -1)
    private val c = candidate(45.0, 1.0, intensity = 0.5, pixel = 1.0, votes = 12, border = 4000)

    @Test fun theDefaultIsBestFitFirst() {
        assertEquals(listOf(a, c, b), HoughLines.sorted(listOf(b, c, a), HoughLines.defaultSort))
    }

    @Test fun everyColumnSorts() {
        val all = listOf(a, b, c)
        assertEquals(listOf(b, c, a), HoughLines.sorted(all, Sort(Column.INTENSITY, true)))
        assertEquals(listOf(c, a, b), HoughLines.sorted(all, Sort(Column.PIXEL, true)))
        assertEquals(listOf(a, c, b), HoughLines.sorted(all, Sort(Column.THETA, true)))
        assertEquals(listOf(b, c, a), HoughLines.sorted(all, Sort(Column.RHO, true)))
        assertEquals(listOf(c, a, b), HoughLines.sorted(all, Sort(Column.VOTES, true)))
        assertEquals(listOf(b, a, c), HoughLines.sorted(all, Sort(Column.BORDER, true)))
        assertEquals(listOf(c, a, b).reversed(), HoughLines.sorted(all, Sort(Column.PIXEL, false)))
    }

    @Test fun clickingAHeaderSortsByItThenTurnsTheOrderRound() {
        val first = HoughLines.clicked(HoughLines.defaultSort, Column.RHO)
        assertEquals(Sort(Column.RHO, true), first)
        assertEquals(Sort(Column.RHO, false), HoughLines.clicked(first, Column.RHO))
    }

    @Test fun theGroupsOwnLineIsTheCandidateWithTheSameAngleAndDistance() {
        val own = Line.newBuilder().setTheta(45.0).setRho(1.0).setVotes(999).build()
        assertTrue(HoughLines.isLine(c, own), "votes do not count")
        assertFalse(HoughLines.isLine(a, own))
        assertFalse(HoughLines.isLine(c, null))
    }

    @Test fun valuesAreShownToTwoPlaces() {
        assertEquals("3.14", HoughLines.format(Math.PI))
        assertEquals("-2.00", HoughLines.format(-2.0))
    }
}
