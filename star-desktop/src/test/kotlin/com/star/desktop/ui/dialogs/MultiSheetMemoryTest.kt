package com.star.desktop.ui.dialogs

import com.star.desktop.domain.MultiFrameRange
import kotlin.test.Test
import kotlin.test.assertEquals

/** E5 of the parity plan: the multi-frame sheets start where the macOS gui's do, and keep what they were left with. */
class MultiSheetMemoryTest {
    @Test fun theSelectSheetStartsOnKeepAllFramesAndFifty() {
        val memory = MultiSheetMemory()
        assertEquals(1, memory.selectAction, "Keep, the second of Remove, Keep, Remove overlaps, Keep overlaps")
        assertEquals(MultiFrameRange.ALL, memory.selectRange)
        assertEquals(MultiFrameRange.ALL, memory.choiceRange)
        assertEquals(50, memory.frameCount)
        assertEquals(50, DEFAULT_FRAME_COUNT)
    }

    /** Index 1 of the select sheet's four actions is Keep (not overlapping), whatever the labels say in another language. */
    @Test fun theDefaultIndexIsTheKeepAction() {
        val keep = listOf(/* remove */ true, /* keep */ false, /* remove overlaps */ true, /* keep overlaps */ false)
        assertEquals(false, keep[MultiSheetMemory().selectAction])
    }
}
