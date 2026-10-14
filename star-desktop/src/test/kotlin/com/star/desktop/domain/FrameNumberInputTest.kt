package com.star.desktop.domain

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class FrameNumberInputTest {
    @Test fun aFrameNumberInRangeIsAccepted() {
        assertEquals(0, FrameNumberInput.parse("0", 10))
        assertEquals(9, FrameNumberInput.parse("9", 10))
        assertEquals(42, FrameNumberInput.parse(" 42 ", 100))
    }

    /** Frames are numbered from 0, so the count itself is one past the end. */
    @Test fun aNumberOutOfRangeIsRefusedNotClamped() {
        assertNull(FrameNumberInput.parse("10", 10))
        assertNull(FrameNumberInput.parse("999", 10))
    }

    @Test fun nothingOrNonsenseIsRefused() {
        assertNull(FrameNumberInput.parse("", 10))
        assertNull(FrameNumberInput.parse("abc", 10))
        assertNull(FrameNumberInput.parse("5", 0))
    }

    @Test fun nonDigitsAreIgnored() {
        assertEquals(12, FrameNumberInput.parse("1a2", 100))
        assertNull(FrameNumberInput.parse("-1", 0))
    }
}
