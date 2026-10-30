package com.star.desktop.data

import com.star.proto.FrameSavingEvent
import com.star.proto.FrameViewMode
import com.star.proto.ImageSaved
import com.star.proto.ProgressEvent
import com.star.proto.SequenceStateEvent
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeoutOrNull
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull

/** How the progress fold treats the run-ending sequence states (A5 `cancelled`, A8 `error`). */
class ProcessingRepositoryTest {
    private fun repo() = ProcessingRepository(CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)) { null }

    private fun seq(state: String, message: String = "") = ProgressEvent.newBuilder()
        .setSequenceState(SequenceStateEvent.newBuilder().setState(state).setMessage(message)).build()

    @Test
    fun errorEndsTheRunAndPublishesTheMessage() = runBlocking {
        val r = repo()
        val got = async { withTimeoutOrNull(2_000) { r.errors.first() } }
        kotlinx.coroutines.yield()
        r.fold(seq("error", "frame 3 failed\nframe 4 failed"))
        assertEquals("frame 3 failed\nframe 4 failed", got.await())
        assertEquals("error", r.sequenceState.value)
        assertFalse(r.processing.value)
    }

    @Test
    fun doneDoesNotPublishAnError() = runBlocking {
        val r = repo()
        r.fold(seq("done"))
        assertEquals("done", r.sequenceState.value)
        assertNull(withTimeoutOrNull(200) { r.errors.first() })
    }

    @Test
    fun cancelledEndsTheRun() {
        val r = repo()
        r.fold(seq("cancelled"))
        assertEquals("cancelled", r.sequenceState.value)
        assertFalse(r.processing.value)
    }

    private fun steps(done: Int) = ProgressEvent.newBuilder()
        .setStepProgress(com.star.proto.StepProgress.newBuilder().addSteps(com.star.proto.StepCount.newBuilder().setType("merge").setDone(done))).build()

    /** L9: "Now" asked while a run is going is refused by the daemon; that must not read as the run having stopped. */
    @Test
    fun aRefusedClaimedRunLeavesTheRunThatIsGoingShowingAsGoing() = runBlocking {
        val r = repo()
        r.startClaimedRun { true }               // a run is going
        r.fold(steps(done = 3))
        assertEquals(true, r.processing.value)

        r.startClaimedRun { false }              // the daemon will not start a second
        assertEquals(true, r.processing.value, "the first run is still going")
        assertEquals(3, r.stepProgress.value?.getSteps(0)?.done, "and its bars are still its own")

        runCatching { r.startClaimedRun { error("RPC error") } }
        assertEquals(true, r.processing.value, "a failed ask is no different")
        assertEquals(3, r.stepProgress.value?.getSteps(0)?.done)
    }

    @Test
    fun aClaimedRunThatBeginsIsARunLikeAnyOther() = runBlocking {
        val r = repo()
        r.fold(steps(done = 9))                  // the last run's bars
        r.startClaimedRun { true }
        assertEquals(true, r.processing.value)
        assertNull(r.stepProgress.value, "cleared as a run starts")
        r.fold(seq("done"))
        assertFalse(r.processing.value)

        r.startClaimedRun { false }              // nothing to refine, and no run was going
        assertFalse(r.processing.value, "nothing began")
    }

    /** What `RenderQuestion` is armed against: each run that begins is the next number, however it was asked for. */
    @Test
    fun everyRunThatBeginsIsTheNextOne() = runBlocking {
        val r = repo()
        assertEquals(0, r.runsStarted)
        runCatching { r.start("s") }                       // no engine: the RPC fails, but the run was asked for
        assertEquals(1, r.runsStarted)
        runCatching { r.restart("s") }
        runCatching { r.reprocessFrames("s", listOf(2), com.star.proto.ReprocessingType.REPROCESS_EVERYTHING) }
        assertEquals(3, r.runsStarted)
        r.startClaimedRun { true }
        assertEquals(4, r.runsStarted)
        r.startClaimedRun { false }                        // refused: not a run
        assertEquals(4, r.runsStarted)
        r.reprocessFrames("s", emptyList(), com.star.proto.ReprocessingType.REPROCESS_EVERYTHING)
        assertEquals(4, r.runsStarted, "no frames, no run")
    }

    @Test
    fun aCancelledThatArrivesAfterTheNextStartIsNotAboutTheNewRun() = runBlocking {
        val r = repo()
        // With no engine the RPCs themselves fail (ignored here); what counts is the bookkeeping.
        r.cancel("s")                // the user stops...
        runCatching { r.start("s") } // ...and starts again before the daemon's cancelled event arrives
        r.fold(seq("cancelled"))
        assertNull(r.sequenceState.value, "the stale cancelled must not become the new run's state")
    }

    private fun saving(frame: Int, new: Int) = ProgressEvent.newBuilder()
        .setFrameSavingState(FrameSavingEvent.newBuilder().setFrameIndex(frame).setNewState(new)).build()

    @Test
    fun pendingSavesCountsFramesWithUnwrittenEdits() {
        val r = repo()
        assertEquals(0, r.pendingSaves.value)
        r.fold(saving(3, 1))   // frame 3 enters purgatory
        r.fold(saving(5, 1))
        assertEquals(2, r.pendingSaves.value)
        r.fold(saving(3, 2))   // pending, then saving: still unwritten, still one frame
        r.fold(saving(3, 3))
        assertEquals(2, r.pendingSaves.value)
        r.fold(saving(3, 0))   // written
        assertEquals(1, r.pendingSaves.value)
        r.fold(saving(5, 0))
        assertEquals(0, r.pendingSaves.value)
    }

    @Test
    fun aSavedImageIsPublishedForTheCacheToDrop() = runBlocking {
        val r = repo()
        val got = async { withTimeoutOrNull(2_000) { r.imageSaved.first() } }
        kotlinx.coroutines.yield()
        r.fold(
            ProgressEvent.newBuilder()
                .setImageSaved(ImageSaved.newBuilder().setFrameIndex(7).setViewMode(FrameViewMode.VIEW_PROCESSED)).build(),
        )
        assertEquals(ProcessingRepository.ImageSaved(7, FrameViewMode.VIEW_PROCESSED), got.await())
    }
}
