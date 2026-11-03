package com.star.desktop.domain

import com.star.desktop.i18n.Strings
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

/** The tray icon's four looks, as the gui's `MenuBarStatusTests` checks the wand's. */
class MenuBarIconTest {
    @BeforeTest fun english() = Strings.setOverride("en")
    @AfterTest fun systemLanguage() = Strings.setOverride(null)

    private val rendering = MenuBarStatus.Rendering(0.25f)
    private val processing = MenuBarStatus.Processing("night-1", null, 10, 40, 0.25f, null)

    @Test fun iconIdForEachState() {
        assertEquals("idle", MenuBarIcon.of(MenuBarStatus.Idle, null).id)
        assertEquals("running", MenuBarIcon.of(rendering, null).id)
        assertEquals("running", MenuBarIcon.of(processing, null).id)
        assertEquals("finished", MenuBarIcon.of(MenuBarStatus.Idle, RunOutcome.FINISHED).id)
        assertEquals("failed", MenuBarIcon.of(MenuBarStatus.Idle, RunOutcome.FAILED).id)
        // A run in progress beats a stale outcome.
        assertEquals("running", MenuBarIcon.of(rendering, RunOutcome.FAILED).id)
    }

    @Test fun finishedAndFailedClearOnMenuOpenAndRunStart() {
        var o = MenuBarOutcome()
        assertNull(o.outcome)
        o = o.runEnded(RunOutcome.FINISHED)
        assertEquals(RunOutcome.FINISHED, o.outcome)
        o = o.menuOpened()
        assertNull(o.outcome)
        o = o.runEnded(RunOutcome.FAILED)
        assertEquals(RunOutcome.FAILED, o.outcome)
        o = o.runStarted()
        assertNull(o.outcome)
        assertNull(o.menuOpened().outcome)
    }

    @Test fun tooltipNamesTheState() {
        assertEquals("star — idle", MenuBarStatus.Idle.tooltip(null))
        assertEquals("star — finished", MenuBarStatus.Idle.tooltip(RunOutcome.FINISHED))
        assertEquals("star — failed", MenuBarStatus.Idle.tooltip(RunOutcome.FAILED))
        assertEquals("star — processing 25%", processing.tooltip(null))
        assertEquals("star — rendering video 25%", rendering.tooltip(null))
    }
}
