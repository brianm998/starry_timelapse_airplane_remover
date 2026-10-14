package com.star.desktop.domain

import com.star.desktop.i18n.Strings
import com.star.proto.StepCount
import com.star.proto.StepProgress
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class StepRowTest {
    @BeforeTest fun english() = Strings.setOverride("en")
    @AfterTest fun systemLanguage() = Strings.setOverride(null)

    @Test fun aBarCoversWhatWasAlreadyDoneAsWellAsThisRun() {
        val row = StepRow("horizon", queued = 20, running = 10, done = 20, alreadyDone = 50)
        assertEquals(100, row.total)
        assertEquals(70, row.completed)
        assertEquals(0.7f, row.doneFraction)
        assertEquals(0.1f, row.runningFraction)
    }

    @Test fun aSequenceResumedHalfWayIsHalfDoneNotStartingFromNothing() {
        val row = StepRow("starKeypoints", queued = 5, running = 0, done = 0, alreadyDone = 5)
        assertEquals(0.5f, row.doneFraction)
    }

    @Test fun aStepWithNothingToItHasNoWork() {
        val row = StepRow("merge", 0, 0, 0, 0)
        assertFalse(row.hasWork)
        assertEquals(0f, row.doneFraction)
    }

    @Test fun everyStepHasANameAndHelpInTheCatalogue() {
        for (type in listOf("horizon", "mergedHorizon", "starKeypoints", "earthKeypoints", "starHomography", "earthHomography", "outliers", "merge")) {
            val row = StepRow(type, 1, 0, 0, 0)
            assertTrue(!row.name.startsWith("ui."), "$type: ${row.name}")
            assertTrue(row.help.startsWith(row.name) && row.help.length > row.name.length, "$type has no help")
        }
    }

    @Test fun anUnknownStepIsNamedByItsType() {
        val row = StepRow("preview", 1, 0, 0, 0)
        assertEquals("preview", row.name)
        assertEquals("preview", row.help)
    }

    @Test fun theRowsAreTheReportsInItsOrder() {
        val report = StepProgress.newBuilder()
            .addSteps(StepCount.newBuilder().setType("horizon").setQueued(1).setRunning(2).setDone(3).setAlreadyDone(4))
            .addSteps(StepCount.newBuilder().setType("merge")).build()
        assertEquals(listOf(StepRow("horizon", 1, 2, 3, 4), StepRow("merge", 0, 0, 0, 0)), StepRow.of(report))
        assertTrue(StepRow.of(null).isEmpty())
    }
}
