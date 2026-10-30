package com.star.desktop.ui.app

import com.star.desktop.ui.app.RenderQuestion.Outcome
import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
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
        val update = source.substringAfter("fun updateSettingsAndProcess(").substringBefore("// \"Show Expert Settings\" is remembered")
        assertTrue("currentSequence?.cancelProcessing()" in update && "requestProcessAll()" in update)
        assertTrue("currentSequence?.restartProcessing()" in update)
    }
}
