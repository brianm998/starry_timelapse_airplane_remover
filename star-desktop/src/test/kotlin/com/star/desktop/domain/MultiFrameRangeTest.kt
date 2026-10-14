package com.star.desktop.domain

import com.star.desktop.i18n.Strings
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

class MultiFrameRangeTest {
    @BeforeTest fun english() = Strings.setOverride("en")
    @AfterTest fun systemLanguage() = Strings.setOverride(null)

    @Test fun theIndicesOfEachChoice() {
        assertEquals(0 to 9, MultiFrameRange.ALL.indices(current = 3, count = 10, n = 5))
        assertEquals(3 to 9, MultiFrameRange.ALL_AFTER.indices(3, 10, 5))
        assertEquals(0 to 3, MultiFrameRange.ALL_BEFORE.indices(3, 10, 5))
        assertEquals(3 to 8, MultiFrameRange.SOME_AFTER.indices(3, 10, 5))
        assertEquals(0 to 3, MultiFrameRange.SOME_BEFORE.indices(3, 10, 5))
    }

    /** From frame 3 of 10 to the end is 7 frames, frames 3 to 9 (macOS's sheet says 8: `count - current + 1`). */
    @Test fun theFrameCountIsTheNumberOfFramesTheRangeReaches() {
        assertEquals(10, MultiFrameRange.ALL.frameCount(3, 10, 5))
        assertEquals(7, MultiFrameRange.ALL_AFTER.frameCount(3, 10, 5))
        assertEquals(4, MultiFrameRange.ALL_BEFORE.frameCount(3, 10, 5))
        assertEquals(3, MultiFrameRange.SOME_AFTER.frameCount(7, 10, 5))     // runs out at the last frame
        assertEquals(3, MultiFrameRange.SOME_BEFORE.frameCount(2, 10, 5))    // runs out at the first
        assertEquals(6, MultiFrameRange.SOME_AFTER.frameCount(0, 10, 5))
    }

    @Test fun theSummaryNamesTheFramesTheActionReaches() {
        assertEquals("Remove outliers in this area in all 10 frames", MultiFrameRange.ALL.summary("ui.area.remove", 3, 10))
        assertEquals(
            "Remove outliers in this area in 7 frames from frame 3 to the end",
            MultiFrameRange.ALL_AFTER.summary("ui.area.remove", 3, 10),
        )
        assertEquals(
            "Clear overlapping outliers in 4 frames from the start ending at frame 3",
            MultiFrameRange.ALL_BEFORE.summary("ui.overlap.clear", 3, 10),
        )
    }

    @Test fun aCountTheUserTypesHasNoSummary() {
        assertNull(MultiFrameRange.SOME_AFTER.summary("ui.area.keep", 3, 10))
        assertNull(MultiFrameRange.SOME_BEFORE.summary("ui.area.keep", 3, 10))
    }

    /** Every sentence the sheets can ask for is in the catalogue (a missing key would show as the key). */
    @Test fun everySummarySentenceExists() {
        val prefixes = listOf(
            "ui.overlap.paint", "ui.overlap.clear",
            "ui.area.remove", "ui.area.keep", "ui.area.remove_overlaps", "ui.area.keep_overlaps",
        )
        for (prefix in prefixes) for (range in listOf(MultiFrameRange.ALL, MultiFrameRange.ALL_AFTER, MultiFrameRange.ALL_BEFORE)) {
            val text = range.summary(prefix, 3, 10)!!
            assertTrue(!text.startsWith("ui."), "$prefix / $range is not in the catalogue: $text")
        }
    }

    @Test fun everyChoiceHasANameInTheCatalogue() {
        for (range in MultiFrameRange.entries) assertTrue(!range.label.startsWith("multi_selection."), "$range: ${range.label}")
    }
}
