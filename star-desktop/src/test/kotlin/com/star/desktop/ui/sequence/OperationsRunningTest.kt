package com.star.desktop.ui.sequence

import com.star.proto.StepCount
import com.star.proto.StepProgress
import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * Q14: "N frames processing" is the operations running now, as the gui counts them (`numberOfFramesProcessingNow`: every step's running
 * operations added up), and not the frames in a working state.
 */
class OperationsRunningTest {
    private fun step(type: String, running: Int) = StepCount.newBuilder().setType(type).setRunning(running).setQueued(7).setDone(3).build()

    @Test fun everyStepsRunningOperationsAreAddedUp() {
        val report = StepProgress.newBuilder()
            .addSteps(step("horizon", 0)).addSteps(step("starKeypoints", 4)).addSteps(step("outliers", 2)).addSteps(step("merge", 1))
            .build()
        assertEquals(7, operationsRunning(report))
    }

    @Test fun nothingIsRunningBeforeTheFirstReport() {
        assertEquals(0, operationsRunning(null))
        assertEquals(0, operationsRunning(StepProgress.getDefaultInstance()))
    }

    @Test fun theEditModeStatusReadsIt() {
        val source = listOf(File("src/main/kotlin/com/star/desktop/ui/sequence/ProcessingStatus.kt"), File("star-desktop/src/main/kotlin/com/star/desktop/ui/sequence/ProcessingStatus.kt"))
            .first { it.isFile }.readText()
        assertTrue("localized(\"ui.n_frames_processing\", operationsRunning(report))" in source)
    }
}
