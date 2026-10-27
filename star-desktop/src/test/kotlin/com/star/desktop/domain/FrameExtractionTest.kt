package com.star.desktop.domain

import com.star.proto.FrameRange
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class FrameExtractionTest {
    private fun range(start: Int, end: Int) = FrameRange.newBuilder().setStart(start).setEnd(end).build()

    @Test fun `ranges from the wire are half open and coalesce`() {
        val set = ExtractedFrames.fromProto(listOf(range(0, 5), range(5, 8), range(20, 21)))
        assertEquals(listOf(0..7, 20..20), set.ranges)
        assertEquals(9, set.count)
        assertTrue(0 in set && 7 in set && 20 in set)
        assertFalse(8 in set || 19 in set || 21 in set || -1 in set)
    }

    @Test fun `an arrival joins what it touches and keeps the rest apart`() {
        var set = ExtractedFrames.fromProto(listOf(range(0, 3)))
        set += listOf(10..12)
        assertEquals(listOf(0..2, 10..12), set.ranges)
        set += listOf(3..9)
        assertEquals(listOf(0..12), set.ranges)
        set += listOf(5..6, 30..29)  // inside what is there, and an empty one
        assertEquals(listOf(0..12), set.ranges)
    }

    @Test fun `the first missing frame skips what is extracted`() {
        val set = ExtractedFrames.fromProto(listOf(range(0, 10), range(12, 20)))
        assertEquals(10, set.firstMissingFrom(0))
        assertEquals(10, set.firstMissingFrom(10))
        assertEquals(20, set.firstMissingFrom(12))
        assertEquals(25, set.firstMissingFrom(25))
        assertEquals(0, ExtractedFrames.NONE.firstMissingFrom(0))
    }

    @Test fun `no frames is nothing`() {
        assertEquals(0, ExtractedFrames.NONE.count)
        assertFalse(0 in ExtractedFrames.NONE)
    }

    @Test fun `durations read in the unit that suits them`() {
        assertEquals("1 s", ExtractionFormat.duration(0.2))
        assertEquals("3 s", ExtractionFormat.duration(2.4))
        assertEquals("89 s", ExtractionFormat.duration(89.0))
        assertEquals("4 min", ExtractionFormat.duration(240.0))
        assertEquals("80 min", ExtractionFormat.duration(80 * 60.0))
        assertEquals("1 h 40 min", ExtractionFormat.duration(100 * 60.0))
    }

    @Test fun `the wait for the in-order extraction is the head's share of the way to the frame`() {
        assertEquals(0.5, ExtractionFormat.sweepFraction(100, 200))
        assertEquals(1.0, ExtractionFormat.sweepFraction(300, 200))
        assertEquals(1.0, ExtractionFormat.sweepFraction(0, 0))
    }
}
