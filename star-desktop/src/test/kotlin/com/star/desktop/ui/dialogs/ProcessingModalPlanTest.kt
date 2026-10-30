package com.star.desktop.ui.dialogs

import com.star.proto.StepProgress
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** P1 of the parity plan: the headline reads "planning" until the daemon says the plan is built, not merely until it has sent a report. */
class ProcessingModalPlanTest {
    @Test fun noReportMeansNoPlan() {
        assertFalse(hasPlan(null))
    }

    /** The first report of a run lists every step with nothing done; treating it as a plan said "finishing up" at the start of every run. */
    @Test fun aReportBeforeTheGraphIsBuiltIsNotAPlan() {
        assertFalse(hasPlan(StepProgress.newBuilder().setGraphBuilt(false).build()))
    }

    @Test fun aReportAfterTheGraphIsBuiltIsAPlan() {
        assertTrue(hasPlan(StepProgress.newBuilder().setGraphBuilt(true).build()))
    }

    @Test fun theHeadlineThatFollows() {
        val planning = com.star.desktop.domain.ProcessingHeadline.text(emptyList(), null, hasPlan(StepProgress.getDefaultInstance()), 0, 10)
        assertEquals(com.star.desktop.i18n.localized("ui.status.planning"), planning)
    }
}
