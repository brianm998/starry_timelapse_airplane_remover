package com.star.desktop.domain

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class FieldInputTest {
    @Test fun aWholeNumberInRangeIsAccepted() {
        assertEquals(5, FieldInput.int("5", 1, 10))
        assertEquals(1, FieldInput.int("1", 1, 10), "the lower bound is in")
        assertEquals(10, FieldInput.int("10", 1, 10), "so is the upper one")
        assertEquals(0, FieldInput.int(" 0 ", 0, 5))
    }

    @Test fun anythingElseIsRefused() {
        assertNull(FieldInput.int("", 1, 10), "an empty box is not a number")
        assertNull(FieldInput.int("0", 1, 10))
        assertNull(FieldInput.int("11", 1, 10))
        assertNull(FieldInput.int("1.5", 1, 10))
        assertNull(FieldInput.int("99999999999", 1, 10))
    }

    @Test fun aDecimalInRangeIsAcceptedAtBothEnds() {
        assertEquals(0.1, FieldInput.double("0.1", 0.1, 0.95))
        assertEquals(0.95, FieldInput.double("0.95", 0.1, 0.95))
        assertEquals(8.0, FieldInput.double("8", 1.0, 8.0))
        assertNull(FieldInput.double("0.09", 0.1, 0.95))
        assertNull(FieldInput.double("0.951", 0.1, 0.95))
        assertNull(FieldInput.double(".", 0.1, 0.95))
        assertNull(FieldInput.double("1.2.3", 0.0, 10.0))
        assertNull(FieldInput.double("NaN", 0.0, 10.0))
        assertNull(FieldInput.double("Infinity", 0.0, Double.POSITIVE_INFINITY))
    }

    @Test fun onlyDigitsAndPointsCanBeTyped() {
        assertEquals("123", FieldInput.wholeNumberChars("1a2-3."))
        assertEquals("1.25", FieldInput.decimalChars("1.2x5"))
    }

    @Test fun boundsAreSaidPlainly() {
        assertEquals("4", FieldInput.bound(4.0))
        assertEquals("0.001", FieldInput.bound(0.001))
        assertEquals("0.95", FieldInput.bound(0.95))
        assertEquals("300", FieldInput.bound(300.0))
        assertEquals("0.1", FieldInput.bound(0.1))
    }
}
