package com.star.desktop.domain

import kotlin.test.Test
import kotlin.test.assertEquals

class FrameNavigationTest {
    @Test fun withNothingMuchSelectedItMovesAlongTheSequenceAndStopsAtTheEnds() {
        assertEquals(6, FrameNavigation.step(5, 1, 10, emptySet()))
        assertEquals(6, FrameNavigation.step(5, 1, 10, setOf(5)))
        assertEquals(9, FrameNavigation.step(8, 20, 10, setOf(8)))
        assertEquals(0, FrameNavigation.step(2, -20, 10, emptySet()))
        assertEquals(0, FrameNavigation.step(0, 0, 0, emptySet()))
    }

    @Test fun withSeveralSelectedItPagesThroughThemInFrameOrder() {
        val selection = setOf(7, 2, 5)
        assertEquals(5, FrameNavigation.step(2, 1, 10, selection))
        assertEquals(7, FrameNavigation.step(5, 1, 10, selection))
        assertEquals(2, FrameNavigation.step(5, -1, 10, selection))
    }

    @Test fun andWrapsRoundAtEitherEnd() {
        val selection = setOf(7, 2, 5)
        assertEquals(2, FrameNavigation.step(7, 1, 10, selection))
        assertEquals(7, FrameNavigation.step(2, -1, 10, selection))
    }

    /** The fast buttons move by that many frames of the selection, which can be more than it has. */
    @Test fun aBigStepGoesRoundTheSelectionMoreThanOnce() {
        val selection = setOf(1, 4, 8)
        assertEquals(8, FrameNavigation.step(1, 5, 10, selection))     // 1 -> 4 -> 8 -> 1 -> 4 -> 8
        assertEquals(4, FrameNavigation.step(1, -5, 10, selection))
        assertEquals(1, FrameNavigation.step(1, 6, 10, selection))
    }

    @Test fun aCurrentFrameOutsideTheSelectionStaysPut() {
        assertEquals(3, FrameNavigation.step(3, 1, 10, setOf(1, 5, 8)))
    }
}
