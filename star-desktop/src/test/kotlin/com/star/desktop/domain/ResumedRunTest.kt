package com.star.desktop.domain

import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * S2 and S3 of the parity plan: after Restart Now (or an engine restart that carries a run on) the "where this sequence left off" panel
 * stayed up over the run, and the run ended without the "render a video?" question. The gui's `restartProcessing` has neither fault.
 * `AppViewModel` cannot be built without an engine, so this pins the two rules and that it uses them.
 */
class ResumedRunTest {
    @Test fun aResumedRunEndsWithTheQuestionUnlessThePromptsAreOff() {
        assertTrue(ResumedRun.asksAboutRenderingAtTheEnd(skipRenderPrompts = false))
        assertFalse(ResumedRun.asksAboutRenderingAtTheEnd(skipRenderPrompts = true))
    }

    @Test fun theProgressPanelIsForASequenceOpenedToLookAt() {
        assertTrue(ResumedRun.showsProgressPanel(resuming = false))
        assertFalse(ResumedRun.showsProgressPanel(resuming = true))
    }

    @Test fun theViewModelAsksBothOfThem() {
        val source = listOf(File("src/main/kotlin/com/star/desktop/ui/app/AppViewModel.kt"), File("star-desktop/src/main/kotlin/com/star/desktop/ui/app/AppViewModel.kt"))
            .first { it.isFile }.readText()
        val resume = source.substringAfter("private fun resumeProcessing()").substringBefore("\n    }\n")
        assertTrue("ResumedRun.asksAboutRenderingAtTheEnd(prefs.skipRenderPromptAfterProcessing)" in resume, "the resume clears the question again")
        assertEquals(2, Regex("ResumedRun\\.showsProgressPanel\\(").findAll(source).count(), "the open that carries on, and the engine restart that does")
        assertTrue("showProgress = com.star.desktop.domain.ResumedRun.showsProgressPanel(resuming = afterOpen != null)" in source)
        assertTrue("showProgress = com.star.desktop.domain.ResumedRun.showsProgressPanel(resuming = wasProcessing)" in source)
    }
}
