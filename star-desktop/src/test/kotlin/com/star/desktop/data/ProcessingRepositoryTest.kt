package com.star.desktop.data

import com.star.proto.FrameSavingEvent
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
}
