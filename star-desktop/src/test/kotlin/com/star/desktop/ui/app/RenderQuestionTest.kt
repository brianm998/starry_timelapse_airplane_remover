package com.star.desktop.ui.app

import com.star.desktop.ui.app.RenderQuestion.Outcome
import com.star.proto.VideoEncodeSettings
import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * P11, P4 and S3 of the parity plan: the question at the end of a run belongs to the run it was asked for. The macOS gui puts it only at the
 * end of Process All's run (`handleProcessingDone`), and a run that replaced another, or was begun some other way, has none.
 */
class RenderQuestionTest {
    @Test fun theRunItWasArmedForEndsWithTheQuestionOrTheRender() {
        val q = RenderQuestion()
        q.arm(forRun = 1, render = false, ask = true)
        assertEquals(Outcome.ASK, q.done(runsStarted = 1))

        q.arm(forRun = 2, render = true, ask = true)
        assertEquals(Outcome.RENDER, q.done(runsStarted = 2), "yes in the first prompt renders, and asks nothing more")

        q.arm(forRun = 3, render = true, ask = false)
        assertEquals(Outcome.RENDER, q.done(runsStarted = 3), "'don't ask again' with 'render after' still renders, as the gui does")
    }

    /** The options chosen after Yes belong to the run armed with them, and go with the question when it is used up or dropped. */
    @Test fun theChosenSettingsReachTheRenderAndAreDroppedWithTheQuestion() {
        val chosen = VideoEncodeSettings.newBuilder().setCodec("prores").setFrameRate(25.0).setOutputHeight(720).build()
        val q = RenderQuestion()
        q.arm(forRun = 1, render = true, ask = true, settings = chosen)
        assertEquals(chosen, q.renderSettings)
        assertEquals(720, q.renderSettings?.outputHeight)
        assertEquals(Outcome.RENDER, q.done(runsStarted = 1))
        assertNull(q.renderSettings, "used up with the question")

        q.arm(forRun = 2, render = true, ask = true, settings = chosen)
        q.disarm()
        assertNull(q.renderSettings, "a stopped run leaves none behind")

        q.arm(forRun = 3, render = true, ask = true, settings = chosen)
        q.arm(forRun = 4, render = false, ask = true)
        assertNull(q.renderSettings, "arming again for another answer replaces them")

        q.arm(forRun = 5, render = false, ask = true, settings = chosen)
        assertNull(q.renderSettings, "settings with no render are not kept")
    }

    @Test fun noQuestionAtAllIsNotArming() {
        val q = RenderQuestion()
        q.arm(forRun = 1, render = false, ask = false)
        assertEquals(Outcome.NOTHING, q.done(runsStarted = 1))
    }

    @Test fun theQuestionIsPutOnceAndUsedUp() {
        val q = RenderQuestion()
        q.arm(1, render = false, ask = true)
        assertEquals(Outcome.ASK, q.done(1))
        assertEquals(Outcome.NOTHING, q.done(1))
        assertEquals(Outcome.NOTHING, q.done(2))
    }

    /** P11: Process All armed it, a re-process (or process from here, or a settings restart) took its place, and that run's end is not the one asked about. */
    @Test fun aRunStartedAfterItWasArmedHasNoQuestion() {
        val q = RenderQuestion()
        q.arm(forRun = 1, render = true, ask = true)
        // run 2 started before run 1 ended, so run 1's end never came; run 2 ends
        assertEquals(Outcome.NOTHING, q.done(runsStarted = 2), "a partial run is not rendered unasked, and does not ask")
        assertEquals(Outcome.NOTHING, q.done(runsStarted = 2))
    }

    @Test fun aStoppedOrFailedRunDropsIt() {
        val q = RenderQuestion()
        q.arm(1, render = true, ask = true)
        q.disarm()
        assertEquals(Outcome.NOTHING, q.done(1))
    }

    @Test fun armingAgainReplacesWhatWasArmed() {
        val q = RenderQuestion()
        q.arm(1, render = true, ask = true)
        q.arm(2, render = false, ask = true)
        assertEquals(Outcome.ASK, q.done(2))
    }

    @Test fun theViewModelUsesItAndAsksAgainAfterASettingsRestart() {
        val source = listOf(File("src/main/kotlin/com/star/desktop/ui/app/AppViewModel.kt"), File("star-desktop/src/main/kotlin/com/star/desktop/ui/app/AppViewModel.kt"))
            .first { it.isFile }.readText()
        assertFalse("autoRenderAfterProcessing" in source || "awaitingProcessingPrompt" in source, "the two flags are RenderQuestion's now")
        assertTrue("renderQuestion.done(currentSequence?.runsStarted ?: 0)" in source)
        assertTrue("renderQuestion.arm(forRun = (currentSequence?.runsStarted ?: 0) + 1" in source)
        // P4: a settings change over a live run stops it and asks again (or restarts in one step when the question is off)
        val update = source.substringAfter("fun updateSettingsAndProcess(").substringBefore("// The Preferences dialog")
        assertTrue("currentSequence?.cancelProcessing()" in update && "requestProcessAll()" in update)
        assertTrue("currentSequence?.restartProcessing()" in update)
    }
}
