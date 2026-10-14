package com.star.desktop.ui.app

import com.star.proto.CleanMethod
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/** Where a freshly opened source writes its output: beside it, so that opening it again finds what was done. */
class InitialConfigBesideTest {
    @Test fun aSequenceWritesNextToItsFolder() {
        assertEquals("/Volumes/x/shoots", initialConfigBeside("/Volumes/x/shoots/milky_way").outputPath)
    }

    /** A video's frames are extracted next to it, so its output goes in the same folder (macOS does the same). */
    @Test fun aVideoWritesNextToTheVideo() {
        assertEquals("/Volumes/x/shoots", initialConfigBeside("/Volumes/x/shoots/clip.mov").outputPath)
    }

    @Test fun theRestOfTheDefaultsAreKept() {
        val config = initialConfigBeside("/a/b/clip.mp4")
        assertEquals(CleanMethod.CLEAN_SELECTIVE, config.cleanMethod)
        assertTrue(config.writeFramePreviewFiles && config.writeOutlierGroupFiles)
    }

    /** A user who always wants Excessive is not asked to say so on every sequence: the type they last chose is where a new one starts. */
    @Test fun aRememberedDetectionTypeSeedsTheNewSequence() {
        assertEquals(com.star.proto.DetectionType.DETECTION_EXCESSIVE, initialConfigBeside("/a/b/seq", com.star.proto.DetectionType.DETECTION_EXCESSIVE).detectionType)
    }

    @Test fun withNoChoiceTheDefaultIsLeftAlone() {
        assertEquals(com.star.proto.DetectionType.DETECTION_MILD, initialConfigBeside("/a/b/seq").detectionType)
    }
}
