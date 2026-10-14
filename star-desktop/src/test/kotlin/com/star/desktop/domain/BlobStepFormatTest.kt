package com.star.desktop.domain

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class BlobStepFormatTest {
    @Test fun anIntegerShowsAsAWholeNumberAndAnythingElseWithTwoDecimals() {
        assertEquals("5000", BlobStepFormat.show(5000.0, isInteger = true))
        assertEquals("86.00", BlobStepFormat.show(86.0, isInteger = false))
        assertEquals("8.10", BlobStepFormat.show(8.1, isInteger = false))
        assertEquals("0", BlobStepFormat.show(0.0, isInteger = true))
        assertEquals("1234.57", BlobStepFormat.show(1234.5678, isInteger = false), "a point, not a comma, whatever the machine's locale")
    }

    @Test fun anIntegerTakesWholeNumbersOnly() {
        assertEquals(30.0, BlobStepFormat.parse(" 30 ", isInteger = true))
        assertEquals(-4.0, BlobStepFormat.parse("-4", isInteger = true))
        assertNull(BlobStepFormat.parse("30.5", isInteger = true))
        assertNull(BlobStepFormat.parse("abc", isInteger = true))
        assertNull(BlobStepFormat.parse("", isInteger = true))
    }

    @Test fun aRealTakesAnyNumber() {
        assertEquals(71.25, BlobStepFormat.parse("71.25", isInteger = false))
        assertEquals(40.0, BlobStepFormat.parse("40", isInteger = false))
        assertNull(BlobStepFormat.parse("x", isInteger = false))
        assertNull(BlobStepFormat.parse("NaN", isInteger = false), "a number that is not one")
        assertNull(BlobStepFormat.parse("Infinity", isInteger = false))
    }
}
