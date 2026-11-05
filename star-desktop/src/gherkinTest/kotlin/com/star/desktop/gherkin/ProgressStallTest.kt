package com.star.desktop.gherkin

import kotlin.test.Test
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue

/**
 * A processing wait fails when the progress line has stopped changing for the stall limit, not after the whole processing timeout
 * (a Windows run sat at 0/19/running for 50 minutes).
 *
 *     ./gradlew gherkinTest --tests '*ProgressStallTest*'
 */
class ProgressStallTest {
    private val minute = 60_000_000_000L
    private var now = 0L
    private fun stall() = ProgressStall(limitNs = 10 * minute, clock = { now })

    @Test fun aRunStuckAtOneStateFailsAfterTheStallLimit() {
        val s = stall()
        s.observe("0/19/running")
        now = 9 * minute
        s.observe("0/19/running")   // nine minutes: still inside the limit
        now = 10 * minute
        val e = assertFailsWith<DesktopFeatureRunner.RunnerError> { s.observe("0/19/running") }
        val message = e.message ?: ""
        assertTrue("0/19/running" in message, "the message names the stuck state: $message")
        assertTrue("10 min" in message, "the message says how long it was stuck: $message")
    }

    @Test fun aChangingStateNeverStalls() {
        val s = stall()
        // Seven minutes between changes, for over two hours: the gap, not the run's length, is what counts.
        for (i in 0..19) {
            s.observe("$i/19/running")
            now += 7 * minute
            s.observe("$i/19/running")
        }
        s.observe("19/19/idle")
    }

    @Test fun theProgressNodeAppearingResetsTheClock() {
        val s = stall()
        now = 8 * minute
        s.observe(null)             // no node yet: the clock runs from the start of the wait
        now = 12 * minute - 1
        s.observe("0/19/running")   // the node appears: that is a change
        now = 21 * minute
        s.observe("0/19/running")
        now = 22 * minute
        assertFailsWith<DesktopFeatureRunner.RunnerError> { s.observe("0/19/running") }
    }

    @Test fun aProgressNodeThatNeverAppearsFailsAfterTheStallLimit() {
        val s = stall()
        now = 10 * minute
        assertFailsWith<DesktopFeatureRunner.RunnerError> { s.observe(null) }
    }
}
