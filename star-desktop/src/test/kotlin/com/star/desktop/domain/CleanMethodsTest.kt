package com.star.desktop.domain

import com.star.proto.CleanMethod
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class CleanMethodsTest {
    @Test fun onlyPlainAutomaticHasNoUseForOutlierTools() {
        assertFalse(CleanMethod.CLEAN_AUTOMATIC.usesOutliers)
        assertTrue(CleanMethod.CLEAN_AUTOMATIC_TRUE.usesOutliers)
        assertTrue(CleanMethod.CLEAN_SELECTIVE.usesOutliers)
    }

    /** Switching to a method with no outlier review leaves no tool selected, as macOS does. */
    @Test fun theToolIsResetWhenTheNewMethodHasNoUseForOne() {
        assertEquals(ToolType.NONE, toolAfterCleanMethodChange(ToolType.KEEP, CleanMethod.CLEAN_AUTOMATIC))
    }

    @Test fun theToolSurvivesAChangeBetweenMethodsThatReviewOutliers() {
        assertEquals(ToolType.RAZOR, toolAfterCleanMethodChange(ToolType.RAZOR, CleanMethod.CLEAN_SELECTIVE))
        assertEquals(ToolType.RAZOR, toolAfterCleanMethodChange(ToolType.RAZOR, CleanMethod.CLEAN_AUTOMATIC_TRUE))
    }
}
