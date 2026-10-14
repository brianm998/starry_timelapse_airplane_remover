package com.star.desktop.domain

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class SavingCountsTest {
    @Test fun eachFrameCountsAtItsStage() {
        val counts = SavingCounts.of(mapOf(0 to 1, 1 to 1, 2 to 2, 3 to 3, 4 to 3, 5 to 3, 6 to 0))
        assertEquals(SavingCounts(purgatory = 2, waiting = 1, saving = 3), counts)
        assertTrue(counts.any)
    }

    @Test fun framesNotSavingAreNotCounted() {
        val counts = SavingCounts.of(mapOf(0 to 0, 1 to 0))
        assertEquals(SavingCounts(0, 0, 0), counts)
        assertFalse(counts.any)
        assertFalse(SavingCounts.of(emptyMap()).any)
    }
}
