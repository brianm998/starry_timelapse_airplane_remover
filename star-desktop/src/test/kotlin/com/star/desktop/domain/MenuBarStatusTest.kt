package com.star.desktop.domain

import com.star.desktop.i18n.Strings
import com.star.desktop.i18n.localized
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * What the tray says ([MenuBarStatus]), as the gui's `MenuBarStatusTests` checks the menu-bar wand. The processing cases check it against what the
 * processing screen builds from the same state: [ProcessingHeadline] for the stage and the time left, and `progress.frames_complete` for the count.
 */
class MenuBarStatusTest {
    @BeforeTest fun english() = Strings.setOverride("en")
    @AfterTest fun systemLanguage() = Strings.setOverride(null)

    private fun step(type: String, queued: Int = 0, running: Int = 0, done: Int = 0) = StepRow(type, queued, running, done, 0)

    /** Star alignment running, merge still queued. */
    private val midRun = listOf(step("starHomography", queued = 30, running = 4, done = 6), step("merge", queued = 40))

    private fun status(
        steps: List<StepRow>,
        sequenceName: String? = "night-1",
        isProcessing: Boolean = true,
        isRendering: Boolean = false,
        renderFraction: Float = 0f,
        secondsRemaining: (StepRow) -> Double? = { null },
    ) = MenuBarStatus.of(
        sequenceName, isProcessing, isRendering, renderFraction, steps, extraction = null, hasPlan = true, statusText = null,
        framesComplete = 10, frameCount = 40, secondsRemaining = secondsRemaining,
    )

    private fun processing(status: MenuBarStatus) = assertNotNull(status as? MenuBarStatus.Processing, "expected a processing status, got $status")

    @Test fun idleWhenNothingIsRunning() {
        // No sequence open: idle, even with stale flags. Then a sequence that is open and doing nothing.
        assertEquals(MenuBarStatus.Idle, status(midRun, sequenceName = null))
        assertEquals(MenuBarStatus.Idle, status(midRun, sequenceName = null, isRendering = true))
        assertEquals(MenuBarStatus.Idle, status(midRun, isProcessing = false))
        assertEquals(listOf("Idle"), MenuBarStatus.Idle.lines())
    }

    @Test fun processingMidRunMatchesTheModalNumbers() {
        val got = processing(status(midRun))
        assertEquals("night-1", got.sequenceName)
        assertEquals(ProcessingHeadline.text(midRun, null, true, 10, 40), got.stage)
        assertEquals(localized("ui.status.working_on", ProcessingHeadline.brief("starHomography")), got.stage)
        assertEquals(10, got.framesDone)
        assertEquals(40, got.frameCount)
        assertEquals(0.25f, got.fraction)
        // The tray's lines carry the same count as the line under the processing screen's title.
        assertTrue(localized("progress.frames_complete", 10, 40) in got.lines())
        assertEquals("10 / 40 frames complete", localized("progress.frames_complete", 10, 40))
        assertEquals("night-1", got.lines().first())
    }

    @Test fun processingWithEtaUnknown() {
        // A tracker that has seen one sample has no rate: the screen says nothing about time left, and neither does the tray.
        val rates = StepRateTracker().also { it.observe(midRun, nowMs = 1_000_000) }
        assertNull(ProcessingHeadline.overallText(midRun) { rates.secondsRemaining(it) })
        val got = processing(status(midRun) { rates.secondsRemaining(it) })
        assertNull(got.overall)
        assertEquals(4, got.lines().size)
    }

    @Test fun processingWithEtaKnown() {
        // Star alignment goes from 6 to 16 done in 10 s, 24 left at 1/s is 24 s; merge has not started, so the figure is a floor.
        val rates = StepRateTracker()
        rates.observe(midRun, nowMs = 1_000_000)
        val later = listOf(step("starHomography", queued = 20, running = 4, done = 16), step("merge", queued = 40))
        rates.observe(later, nowMs = 1_010_000)
        val expected = ProcessingHeadline.overallText(later) { rates.secondsRemaining(it) }
        assertNotNull(expected)
        val got = processing(status(later) { rates.secondsRemaining(it) })
        assertEquals(expected, got.overall)
        assertEquals(localized("ui.status.overall_at_least", ProcessingHeadline.duration(24.0)), got.overall)
        assertEquals(expected, got.lines().last())
    }

    @Test fun renderingShowsFraction() {
        assertEquals(MenuBarStatus.Rendering(0.4f), status(emptyList(), isProcessing = false, isRendering = true, renderFraction = 0.4f))
        // Rendering wins over a stale processing flag, and the fraction stays in 0..1.
        assertEquals(MenuBarStatus.Rendering(1f), status(midRun, isRendering = true, renderFraction = 1.7f))
        assertEquals(listOf("Rendering video", "████░░░░░░░░ 40%"), MenuBarStatus.Rendering(0.4f).lines())
    }
}
