package com.star.desktop.domain

import com.star.desktop.i18n.Strings
import com.star.proto.AlignmentInfo
import com.star.proto.AlignmentState
import com.star.proto.HomographyResults
import com.star.proto.NeighborHomography
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class AlignmentChartsTest {
    @BeforeTest fun english() = Strings.setOverride("en")
    @AfterTest fun systemLanguage() = Strings.setOverride(null)

    private fun neighbor(frame: Int, deviation: Double, suspect: Boolean = false, state: AlignmentState = AlignmentState.ALIGN_HOMOGRAPHY_SUCCESS) =
        NeighborHomography.newBuilder().setFrameIndex(frame).setDeviation(deviation).setSuspect(suspect).setState(state).build()

    private fun info(frame: Int, neighbors: List<NeighborHomography>, earth: List<NeighborHomography>? = null, sky: Int = -1, ground: Int = -1) =
        AlignmentInfo.newBuilder().setFrameIndex(frame).setHasStarResults(true).setAllowEarthAlignment(earth != null)
            .setNumSkyKeypoints(sky).setNumEarthKeypoints(ground)
            .setStar(HomographyResults.newBuilder().setFrameIndex(frame).addAllNeighbors(neighbors))
            .also { if (earth != null) it.setHasEarthResults(true).setEarth(HomographyResults.newBuilder().setFrameIndex(frame).addAllNeighbors(earth)) }
            .build()

    // ---- the readings

    @Test fun aReadingIsSignedByTheOffsetAndOwnEntriesAreSkipped() {
        val points = AlignmentCharts.points(listOf(info(5, listOf(neighbor(4, 2.0), neighbor(5, 0.0), neighbor(7, 3.0))))) { it.star }
        assertEquals(listOf(-1 to -2.0, 2 to 3.0), points.map { it.offset to it.deviation })
        assertTrue(points.none { it.offset == 0 })
    }

    @Test fun aSuspectWarpIsNotGood() {
        val points = AlignmentCharts.points(listOf(info(0, listOf(neighbor(1, 1.0), neighbor(2, 2.0, suspect = true))))) { it.star }
        assertEquals(listOf(true, false), points.map { it.isGood })
    }

    @Test fun framesWithoutResultsGiveNoReadings() {
        val none = AlignmentInfo.newBuilder().setFrameIndex(0).build()
        assertTrue(AlignmentCharts.points(listOf(none)) { if (it.hasStarResults) it.star else null }.isEmpty())
    }

    @Test fun oneLinePerOffsetInFrameOrder() {
        val frames = listOf(info(2, listOf(neighbor(3, 1.0), neighbor(1, 1.0))), info(1, listOf(neighbor(2, 1.0))))
        val lines = AlignmentCharts.byOffset(AlignmentCharts.points(frames) { it.star })
        assertEquals(listOf(-1, 1), lines.map { it.first })
        assertEquals(listOf(1, 2), lines.last().second.map { it.frame }, "sorted by frame within an offset")
    }

    @Test fun theLegendListsTheOffsetsOfTheSeriesThatAreShowing() {
        val star = AlignmentCharts.points(listOf(info(5, listOf(neighbor(4, 1.0), neighbor(6, 1.0))))) { it.star }
        val earth = AlignmentCharts.points(listOf(info(5, emptyList(), earth = listOf(neighbor(3, 1.0), neighbor(6, 1.0))))) { it.earth }
        assertEquals(listOf(-1, 1), AlignmentCharts.visibleOffsets(star))
        assertEquals(listOf(-2, -1, 1), AlignmentCharts.visibleOffsets(star, earth))
        assertEquals(emptyList(), AlignmentCharts.visibleOffsets())
    }

    @Test fun hoveringPicksTheReadingNearestAtThatFrame() {
        val points = AlignmentCharts.points(listOf(info(5, listOf(neighbor(3, 10.0), neighbor(4, 2.0), neighbor(6, 4.0))))) { it.star }
        // Readings at frame 5: offset -2 at -10, offset -1 at -2, offset +1 at +4 (signed by offset, so the two sides separate).
        assertEquals(1, AlignmentCharts.closest(points, 5, 2.4)?.offset)
        assertEquals(-1, AlignmentCharts.closest(points, 5, -2.5)?.offset)
        assertEquals(-2, AlignmentCharts.closest(points, 5, -30.0)?.offset)
    }

    @Test fun hoveringAFrameWithNoReadingsPicksNothing() {
        val points = AlignmentCharts.points(listOf(info(5, listOf(neighbor(4, 2.0))))) { it.star }
        assertNull(AlignmentCharts.closest(points, 9, 0.0))
    }

    // ---- the data

    @Test fun keypointCountsAreNullWhereUnknown() {
        val data = AlignmentData(listOf(info(0, emptyList(), sky = 120), info(1, emptyList(), sky = -1), info(2, emptyList(), sky = 0)))
        assertEquals(listOf(120, null, 0), data.skyKeypoints)
    }

    @Test fun earthChartsNeedEarthAlignmentOn() {
        assertTrue(AlignmentData(listOf(info(0, emptyList(), earth = listOf(neighbor(1, 1.0))))).allowEarth)
        assertFalse(AlignmentData(listOf(info(0, emptyList()))).allowEarth)
        assertFalse(AlignmentData.EMPTY.hasStar)
    }

    // ---- the colours

    @Test fun anOffsetAndItsNegativeShareAColourAndTheNearestNeighborsTakeTheFirstOnes() {
        assertEquals(0, AlignmentCharts.paletteIndex(1))
        assertEquals(0, AlignmentCharts.paletteIndex(-1))
        assertEquals(1, AlignmentCharts.paletteIndex(2))
        assertEquals(7, AlignmentCharts.paletteIndex(8))
        assertEquals(0, AlignmentCharts.paletteIndex(9), "wraps after eight")
    }

    // ---- words

    @Test fun offsetsAndStatesAreSaidTheMacWay() {
        assertEquals("+2", AlignmentCharts.offsetLabel(2))
        assertEquals("-3", AlignmentCharts.offsetLabel(-3))
        assertEquals("success", AlignmentCharts.stateLabel(AlignmentState.ALIGN_HOMOGRAPHY_SUCCESS))
        assertEquals("not enough keypoints", AlignmentCharts.stateLabel(AlignmentState.ALIGN_NOT_ENOUGH_KEYPOINTS))
        for (s in AlignmentState.values().filter { it != AlignmentState.UNRECOGNIZED }) {
            assertFalse(AlignmentCharts.stateLabel(s).startsWith("alignment_state."), "$s has no words")
        }
    }

    // ---- the x axis

    @Test fun theFullDomainSpansTheSequence() {
        assertEquals(XDomain(0, 99), XDomain.full(100))
        assertEquals(XDomain(0, 0), XDomain.full(1))
        assertEquals(XDomain(0, 0), XDomain.full(0))
    }

    @Test fun aFrameIsNamedByItsPositionOverThePlot() {
        val domain = XDomain(100, 200)
        assertEquals(100, AlignmentCharts.frameAt(0f, 400f, domain))
        assertEquals(150, AlignmentCharts.frameAt(200f, 400f, domain))
        assertEquals(200, AlignmentCharts.frameAt(400f, 400f, domain))
        assertEquals(200, AlignmentCharts.frameAt(900f, 400f, domain), "off the right edge is the last frame")
        assertEquals(100, AlignmentCharts.frameAt(-5f, 400f, domain))
    }

    @Test fun zoomingInNeverGoesBelowTwentyFrames() {
        var d = XDomain.full(1000)
        repeat(20) { d = d.zoomed(2.0, 1000) }
        assertEquals(XDomain.MIN_SPAN, d.span)
    }

    @Test fun zoomingOutNeverGoesPastTheSequence() {
        var d = XDomain(400, 500)
        repeat(20) { d = d.zoomed(0.5, 1000) }
        assertEquals(XDomain(0, 999), d)
    }

    @Test fun zoomingKeepsTheFrameUnderThePointerWhereItIs() {
        val d = XDomain(0, 999).zoomed(4.0, 1000, anchor = 750.0)
        assertEquals(250, d.span)
        // 750 was three quarters across, and still is.
        assertEquals(0.75, (750 - d.lower).toDouble() / d.span, 0.01)
    }

    @Test fun zoomingNearAnEdgeStaysInsideTheSequence() {
        val d = XDomain(0, 999).zoomed(10.0, 1000, anchor = 0.0)
        assertEquals(XDomain(0, 100), d)
        val e = XDomain(0, 999).zoomed(10.0, 1000, anchor = 999.0)
        assertEquals(999, e.upper)
        assertEquals(100, e.span)
    }

    @Test fun aShortSequenceCannotBeZoomedPastItsOwnLength() {
        val d = XDomain.full(10).zoomed(5.0, 10)
        assertEquals(XDomain(0, 9), d)
    }

    @Test fun panningKeepsTheWidthAndStopsAtTheEnds() {
        val d = XDomain(100, 200)
        assertEquals(XDomain(130, 230), d.panned(30, 1000))
        assertEquals(XDomain(0, 100), d.panned(-500, 1000))
        assertEquals(XDomain(899, 999), d.panned(5000, 1000))
    }

    @Test fun theChartFollowsTheCurrentFrameOnlyWhenItLeavesThePicture() {
        val d = XDomain(100, 200)
        assertEquals(d, d.ensuring(150, 1000))
        assertEquals(d, d.ensuring(100, 1000))
        val moved = d.ensuring(500, 1000)
        assertTrue(500 in moved)
        assertEquals(100, moved.span)
        assertEquals(XDomain(0, 100), d.ensuring(3, 1000), "near the start it stops at the start")
    }

    // ---- ticks

    @Test fun ticksAreRoundNumbers() {
        assertEquals(listOf(-50.0, 0.0, 50.0), ChartTicks.nice(-50.0, 50.0, 4))
        assertEquals(listOf(-40.0, -20.0, 0.0, 20.0, 40.0), ChartTicks.nice(-50.0, 50.0, 5), "steps of 1, 2 or 5 times a power of ten")
        assertEquals(listOf(0.0, 20.0, 40.0, 60.0, 80.0, 100.0), ChartTicks.nice(0.0, 100.0, 5))
        assertEquals(listOf(0.0, 100.0, 200.0, 300.0), ChartTicks.nice(0.0, 300.0, 3))
    }

    @Test fun aDegenerateRangeHasOneTick() {
        assertEquals(listOf(5.0), ChartTicks.nice(5.0, 5.0, 5))
    }

    @Test fun tickLabelsAreWholeNumbersWhenTheyCanBe() {
        assertEquals("25", ChartTicks.label(25.0))
        assertEquals("0.5", ChartTicks.label(0.5))
        assertEquals("-10", ChartTicks.label(-10.0))
    }
}
