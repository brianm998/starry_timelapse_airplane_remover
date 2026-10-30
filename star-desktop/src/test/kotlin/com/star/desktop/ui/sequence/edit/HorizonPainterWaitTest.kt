package com.star.desktop.ui.sequence.edit

import com.star.desktop.domain.ExtractedFrames
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** H3 of the parity plan: the painter waits for a frame the video has not given up yet, as the gui does, instead of falling back to band selection on a blank frame. */
@OptIn(ExperimentalCoroutinesApi::class)
class HorizonPainterWaitTest {
    @Test fun anImageSequenceHasNothingToWaitFor() = runTest {
        awaitFrameExtracted(MutableStateFlow(null), 7)
    }

    @Test fun aFrameThatIsAlreadyThereIsNotWaitedFor() = runTest {
        awaitFrameExtracted(MutableStateFlow(ExtractedFrames.of(listOf(0..9))), 7)
    }

    @Test fun aFrameStillBeingExtractedIsWaitedForUntilItArrives() = runTest(UnconfinedTestDispatcher()) {
        val frames = MutableStateFlow<ExtractedFrames?>(ExtractedFrames.of(listOf(0..3)))
        var arrived = false
        val waiting = launch(start = CoroutineStart.UNDISPATCHED) { awaitFrameExtracted(frames, 7); arrived = true }
        assertFalse(arrived, "frame 7 is not extracted yet")
        frames.value = ExtractedFrames.of(listOf(0..5))
        assertFalse(arrived, "frames 0..5 are, 7 is not")
        frames.value = ExtractedFrames.of(listOf(0..9))
        waiting.join()
        assertTrue(arrived)
        assertEquals(true, 7 in frames.value!!)
    }
}
