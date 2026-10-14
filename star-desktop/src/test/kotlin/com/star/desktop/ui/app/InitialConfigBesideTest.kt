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
}
