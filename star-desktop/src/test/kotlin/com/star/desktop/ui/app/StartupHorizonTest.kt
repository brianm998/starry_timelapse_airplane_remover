package com.star.desktop.ui.app

import kotlin.test.Test
import kotlin.test.assertEquals

/**
 * Verifies the moving-horizon startup frame spacing matches macOS
 * `ImageSequenceViewModel.calculateFrameIndices` exactly (first = 0, last = total-1, evenly spread).
 */
class StartupHorizonTest {

    @Test fun singleHorizonIsFirstFrame() {
        assertEquals(listOf(0), evenlySpacedFrameIndices(count = 1, total = 100))
    }

    @Test fun threeHorizonsSpanFirstMiddleLast() {
        assertEquals(listOf(0, 5, 9), evenlySpacedFrameIndices(count = 3, total = 10))
    }

    @Test fun fiveHorizonsAreEvenlySpaced() {
        // round(i * 99 / 4): 0, 24.75→25, 49.5→50, 74.25→74, 99
        assertEquals(listOf(0, 25, 50, 74, 99), evenlySpacedFrameIndices(count = 5, total = 100))
    }

    @Test fun countAtOrAboveTotalReturnsEveryFrame() {
        assertEquals((0 until 4).toList(), evenlySpacedFrameIndices(count = 4, total = 4))
        assertEquals((0 until 4).toList(), evenlySpacedFrameIndices(count = 9, total = 4))
    }

    @Test fun firstAndLastAreAlwaysEndpoints() {
        val idx = evenlySpacedFrameIndices(count = 7, total = 41)
        assertEquals(0, idx.first())
        assertEquals(40, idx.last())
        assertEquals(7, idx.size)
    }

    @Test fun degenerateInputsAreEmpty() {
        assertEquals(emptyList(), evenlySpacedFrameIndices(count = 0, total = 10))
        assertEquals(emptyList(), evenlySpacedFrameIndices(count = 3, total = 0))
    }

    // the suggested count (macOS `suggestedMovingHorizonCount`)

    @Test fun suggestionScalesWithSequenceLength() {
        assertEquals(12, suggestedMovingHorizonCount(1450)) // the measured good value
        assertEquals(10, suggestedMovingHorizonCount(1000))
        assertEquals(14, suggestedMovingHorizonCount(2000))
        assertEquals(22, suggestedMovingHorizonCount(5000))
    }

    @Test fun shortSequencesKeepTheOldSuggestionOfThree() {
        assertEquals(3, suggestedMovingHorizonCount(50))
        assertEquals(3, suggestedMovingHorizonCount(122))
        assertEquals(4, suggestedMovingHorizonCount(123)) // where sqrt(total/10) rounds past 3
    }

    @Test fun suggestionNeverExceedsTheSequence() {
        assertEquals(1, suggestedMovingHorizonCount(1))
        assertEquals(2, suggestedMovingHorizonCount(2))
        assertEquals(1, suggestedMovingHorizonCount(0)) // matches the stepper's floor of 1
    }

    @Test fun suggestionIsAlwaysAValidStepperValue() {
        for (total in 1..6000) {
            val n = suggestedMovingHorizonCount(total)
            assertEquals(true, n in 1..total, "suggestion $n out of 1..$total")
        }
    }
}
