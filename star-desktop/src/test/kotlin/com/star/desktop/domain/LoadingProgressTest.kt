package com.star.desktop.domain

import com.star.desktop.i18n.Strings
import com.star.proto.FramesLoaded
import com.star.proto.IoProgress
import com.star.proto.OpenProgress
import com.star.proto.OpenStage
import com.star.proto.OpenStageEvent
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class LoadingProgressTest {
    @BeforeTest fun english() = Strings.setOverride("en")
    @AfterTest fun systemLanguage() = Strings.setOverride(null)

    private fun stage(s: OpenStage, name: String = "") =
        OpenProgress.newBuilder().setStage(OpenStageEvent.newBuilder().setStage(s).setName(name)).build()

    private fun extracted(current: Int, total: Int) =
        OpenProgress.newBuilder().setProgress(IoProgress.newBuilder().setCurrent(current).setTotal(total)).build()

    private fun loaded(loaded: Int, total: Int) =
        OpenProgress.newBuilder().setLoaded(FramesLoaded.newBuilder().setLoaded(loaded).setTotal(total)).build()

    @Test fun aVideoStartsByBeingExaminedAndAnythingElseByLoading() {
        assertEquals(LoadingProgress.Stage.EXAMINING, LoadingProgress.starting("v.mov", video = true).stage)
        assertEquals(LoadingProgress.Stage.LOADING, LoadingProgress.starting("seq", video = false).stage)
    }

    @Test fun examiningAVideoHasNothingToMeasure() {
        val p = LoadingProgress.starting("v.mov", video = true)
        assertNull(p.fraction)
        assertFalse(p.isComplete)
        assertEquals("Examining Video", p.caption)
    }

    @Test fun extractionCountsFramesUpToTheTotalAndThenSaysSo() {
        var p = LoadingProgress.starting("v.mov", video = true)
        p = p.after(stage(OpenStage.OPEN_STAGE_EXTRACTING_FRAMES))
        p = p.after(extracted(30, 120))
        assertEquals(0.25f, p.fraction)
        assertEquals("30 frames extracted", p.caption)
        assertFalse(p.isComplete)

        p = p.after(extracted(120, 120))
        assertTrue(p.isComplete)
        assertEquals("All 120 frames extracted", p.caption)
    }

    @Test fun loadingFramesStartsFromZeroWhenItFollowsExtraction() {
        var p = LoadingProgress.starting("v.mov", video = true).after(extracted(120, 120))
        p = p.after(stage(OpenStage.OPEN_STAGE_LOADING_FRAMES))
        assertEquals(LoadingProgress.Stage.LOADING, p.stage)
        assertEquals(0, p.current)
        assertFalse(p.isComplete, "the extraction's total must not carry into the loading ring")
        p = p.after(loaded(40, 120))
        assertEquals("40 frames loaded", p.caption)
        p = p.after(loaded(120, 120))
        assertEquals("All 120 frames loaded", p.caption)
        assertTrue(p.isComplete)
    }

    @Test fun theNameIsKeptUntilAnEventBringsANewOne() {
        var p = LoadingProgress.starting("config.json", video = false)
        p = p.after(stage(OpenStage.OPEN_STAGE_LOADING_FRAMES, name = "night_sky"))
        assertEquals("night_sky", p.name)
        assertEquals("Loading night_sky", p.title)
        p = p.after(loaded(3, 10))
        assertEquals("night_sky", p.name)
        p = p.after(stage(OpenStage.OPEN_STAGE_LOADING_FRAMES))
        assertEquals("night_sky", p.name, "an event with no name does not erase it")
    }

    @Test fun aRepeatedStageEventKeepsTheCount() {
        var p = LoadingProgress.starting("seq", video = false).after(loaded(5, 10))
        p = p.after(stage(OpenStage.OPEN_STAGE_LOADING_FRAMES))
        assertEquals(5, p.current)
    }

    @Test fun anEventWithNoNewsChangesNothing() {
        val p = LoadingProgress.starting("seq", video = false).after(loaded(5, 10))
        assertEquals(p, p.after(OpenProgress.getDefaultInstance()))
    }

    @Test fun theRingNeverLeavesItsTrack() {
        assertEquals(1f, LoadingProgress("s", LoadingProgress.Stage.LOADING, 12, 10).fraction)
        assertNull(LoadingProgress("s", LoadingProgress.Stage.LOADING, 0, 0).fraction, "nothing to measure until the total is known")
    }
}
