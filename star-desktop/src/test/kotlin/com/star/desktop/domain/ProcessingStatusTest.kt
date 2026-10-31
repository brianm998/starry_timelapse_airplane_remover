package com.star.desktop.domain

import com.star.proto.FrameProcessingState
import com.star.proto.FrameProcessingState.FPS_COMPLETE
import com.star.proto.FrameProcessingState.FPS_HORIZON_DETECTED
import com.star.proto.FrameProcessingState.FPS_STAR_KEYPOINTS
import com.star.proto.FrameProcessingState.FPS_UNPROCESSED
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class ProcessingStatusTest {
    private fun counts(frameCount: Int, vararg states: Pair<Int, FrameProcessingState>) = FrameStateCounts(states.toMap(), frameCount)

    @Test fun framesTheDaemonHasNotReportedOnAreUnprocessed() {
        val c = counts(10, 0 to FPS_COMPLETE, 1 to FPS_UNPROCESSED, 2 to FPS_STAR_KEYPOINTS)
        assertEquals(8, c.unprocessed)        // 1 reported unprocessed + 7 not reported
        assertEquals(8, c[FPS_UNPROCESSED])
        assertEquals(1, c.complete)
        assertEquals(1, c.working)
    }

    @Test fun theProgressBarsSegmentsAreFractionsOfTheSequence() {
        val (done, working, left) = counts(4, 0 to FPS_COMPLETE, 1 to FPS_COMPLETE, 2 to FPS_STAR_KEYPOINTS).fractions()
        assertEquals(0.5f, done); assertEquals(0.25f, working); assertEquals(0.25f, left)
        assertEquals(Triple(0f, 0f, 0f), counts(0).fractions())
    }

    @Test fun whileARunIsGoingTheButtonIsStatusAndNeverDisabled() {
        val role = ProcessingButtonRole.current(true, isRendering = true, counts(3, 0 to FPS_COMPLETE, 1 to FPS_COMPLETE, 2 to FPS_COMPLETE), 3, false)
        assertEquals(ProcessingButtonRole.Status, role)
    }

    @Test fun withFramesLeftTheButtonProcessesAndIsEnabled() {
        val role = ProcessingButtonRole.current(false, false, counts(3, 0 to FPS_COMPLETE), 3, false)
        assertEquals(ProcessingButtonRole.Process(true), role)
    }

    @Test fun withNothingLeftTheButtonIsDisabled() {
        val done = counts(2, 0 to FPS_COMPLETE, 1 to FPS_COMPLETE)
        assertEquals(ProcessingButtonRole.Process(false), ProcessingButtonRole.current(false, false, done, 2, false))
    }

    /** A horizon repainted after the frames were rendered is work a finished sequence is still owed. */
    @Test fun aPendingHorizonRefinementIsWorkLeft() {
        val done = counts(2, 0 to FPS_COMPLETE, 1 to FPS_COMPLETE)
        assertEquals(ProcessingButtonRole.Process(true), ProcessingButtonRole.current(false, false, done, 2, true))
    }

    /** Every frame stopped at horizon detection is the other state worth processing from. */
    @Test fun framesAllStoppedAtHorizonDetectionAreWorkLeft() {
        val stopped = counts(2, 0 to FPS_HORIZON_DETECTED, 1 to FPS_HORIZON_DETECTED)
        assertEquals(ProcessingButtonRole.Process(true), ProcessingButtonRole.current(false, false, stopped, 2, false))
    }

    @Test fun aRenderInProgressDisablesIt() {
        assertEquals(ProcessingButtonRole.Process(false), ProcessingButtonRole.current(false, true, counts(3, 0 to FPS_COMPLETE), 3, false))
    }

    private fun layout(complete: Int, frames: Int = 10, processing: Boolean = false, rendering: Boolean = false, pending: Boolean = false) =
        ProcessingButtonsLayout.current(processing, rendering, complete, frames, pending)

    @Test fun aFreshOrPartlyDoneSequenceShowsProcessAndNotRender() {
        for (done in listOf(0, 9)) {
            assertEquals(ProcessingButtonsLayout(showsProcess = true, showsRender = false, renderEnabled = false), layout(done))
        }
    }

    @Test fun aRunInProgressShowsItsStatusAndNotRender() {
        assertEquals(ProcessingButtonsLayout(showsProcess = true, showsRender = false, renderEnabled = false), layout(4, processing = true))
    }

    /** The last frame can be complete a moment before the run is over. */
    @Test fun everyFrameCompleteWhileTheRunIsStillGoingIsNotComplete() {
        assertEquals(ProcessingButtonsLayout(showsProcess = true, showsRender = false, renderEnabled = false), layout(10, processing = true))
    }

    @Test fun aCompleteSequenceShowsRenderVideoInPlaceOfProcess() {
        assertEquals(ProcessingButtonsLayout(showsProcess = false, showsRender = true, renderEnabled = true), layout(10))
    }

    @Test fun aVideoBeingWrittenLeavesRenderOnScreenButOff() {
        assertEquals(ProcessingButtonsLayout(showsProcess = false, showsRender = true, renderEnabled = false), layout(10, rendering = true))
    }

    /** A horizon reference still to be applied is work the sequence is owed, so it is not done, whatever its frame states say. */
    @Test fun aPendingHorizonRefinementIsNotComplete() {
        assertEquals(ProcessingButtonsLayout(showsProcess = true, showsRender = false, renderEnabled = false), layout(10, pending = true))
    }

    /** 0 == 0 is not a finished sequence; there is nothing to render a video from. */
    @Test fun noFramesIsNotComplete() {
        assertEquals(ProcessingButtonsLayout(showsProcess = true, showsRender = false, renderEnabled = false), layout(0, frames = 0))
    }

    @Test fun onlyTheModesTheFrameHasAreListedAndTheBasicOnesUntilExpanded() {
        val available = listOf(
            com.star.proto.FrameViewMode.VIEW_ORIGINAL, com.star.proto.FrameViewMode.VIEW_STAR_ALIGNED, com.star.proto.FrameViewMode.VIEW_PROCESSED,
        )
        assertEquals(
            listOf(com.star.proto.FrameViewMode.VIEW_ORIGINAL, com.star.proto.FrameViewMode.VIEW_PROCESSED),
            ViewModes.shown(available, expanded = false),
        )
        assertEquals(
            listOf(com.star.proto.FrameViewMode.VIEW_ORIGINAL, com.star.proto.FrameViewMode.VIEW_STAR_ALIGNED, com.star.proto.FrameViewMode.VIEW_PROCESSED),
            ViewModes.shown(available, expanded = true),
        )
        assertTrue(ViewModes.shown(emptyList(), true).isEmpty())
    }
}
