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
}
