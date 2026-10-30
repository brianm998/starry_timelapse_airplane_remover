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

class ProcessingHeadlineTest {
    @BeforeTest fun english() = Strings.setOverride("en")
    @AfterTest fun systemLanguage() = Strings.setOverride(null)

    private fun step(type: String, queued: Int = 0, running: Int = 0, done: Int = 0) = StepRow(type, queued, running, done, 0)

    private fun text(steps: List<StepRow>, hasPlan: Boolean = true, complete: Int = 0) =
        ProcessingHeadline.text(steps, null, hasPlan, complete, 10)

    @Test fun planningUntilTheDaemonHasReported() {
        assertEquals(localized("ui.status.planning"), text(listOf(step("horizon")), hasPlan = false))
    }

    @Test fun namesEveryRunningStep() {
        val steps = listOf(
            step("horizon", queued = 3, running = 2, done = 5), step("starKeypoints", queued = 5, running = 2, done = 3),
            step("earthHomography", queued = 4), step("merge", queued = 10),
        )
        assertEquals(localized("ui.status.working_on", "${ProcessingHeadline.brief("horizon")}, ${ProcessingHeadline.brief("starKeypoints")}"), text(steps))
    }

    @Test fun fallsBackToTheFirstQueuedStep() {
        assertEquals(ProcessingHeadline.activity("starKeypoints"), text(listOf(step("horizon", done = 10), step("starKeypoints", queued = 10))))
    }

    @Test fun overallEstimateIsTheSlowestMeasuredStep() {
        val steps = listOf(step("horizon", queued = 3, running = 2, done = 5), step("starKeypoints", queued = 5, running = 2, done = 3))
        assertEquals(
            localized("ui.status.overall_about", localized("duration.minutes", 10)),
            ProcessingHeadline.overallText(steps) { if (it.type == "horizon") 120.0 else 600.0 },
        )
    }

    @Test fun overallEstimateAdmitsWhatItCannotSeeYet() {
        val steps = listOf(step("starKeypoints", queued = 5, running = 2, done = 3), step("merge", queued = 10))
        assertEquals(
            localized("ui.status.overall_at_least", localized("duration.minutes", 10)),
            ProcessingHeadline.overallText(steps) { if (it.type == "merge") null else 600.0 },
        )
        assertNull(ProcessingHeadline.overallText(steps) { null })
    }

    @Test fun finishingWhileFramesRemainAndQuietOnceDone() {
        val done = listOf(step("merge", done = 10))
        assertEquals(localized("ui.status.finishing"), text(done, complete = 9))
        assertNull(text(done, complete = 10))
    }

    @Test fun everyStepHasAnActivitySentence() {
        for (type in listOf("horizon", "mergedHorizon", "starKeypoints", "earthKeypoints", "starHomography", "earthHomography", "horizonConsensus", "outliers", "merge")) {
            assertTrue(ProcessingHeadline.activity(type).let { it.isNotEmpty() && !it.startsWith("ui.") }, type)
        }
    }

    @Test fun rateNeedsOperationsAndTime() {
        val tracker = StepRateTracker()
        tracker.observe(listOf(step("merge", queued = 8, running = 2)), 0)
        val later = step("merge", queued = 6, running = 2, done = 2)
        tracker.observe(listOf(later), 1000)
        assertNull(tracker.secondsRemaining(later))
        val end = step("merge", queued = 4, running = 2, done = 4)
        tracker.observe(listOf(end), 8000)
        assertEquals(12.0, assertNotNull(tracker.secondsRemaining(end)), 0.001)
    }

    @Test fun durationRoundsCoarsely() {
        assertEquals(localized("duration.seconds", 5), ProcessingHeadline.duration(3.0))
        assertEquals(localized("duration.minutes", 2), ProcessingHeadline.duration(100.0))
        assertEquals(localized("duration.hours_minutes", 1, 30), ProcessingHeadline.duration(5400.0))
    }
}
