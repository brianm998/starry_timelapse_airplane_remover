package com.star.desktop.ui.sequence

import com.star.desktop.data.ExportRepository
import com.star.desktop.data.FrameRepository
import com.star.desktop.data.HorizonRepository
import com.star.desktop.data.ImageCache
import com.star.desktop.data.OutlierRepository
import com.star.desktop.data.ProcessingRepository
import com.star.desktop.domain.InteractionMode
import com.star.desktop.domain.VideoPlayMode
import com.star.proto.SessionInfo
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeoutOrNull
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

/** Transport and playback of a sequence view model with no engine behind it (every picture is simply unavailable). */
class PlaybackTest {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    @AfterTest fun stop() { scope.cancel() }

    private fun vm(frames: Int): SequenceViewModel {
        val info = SessionInfo.newBuilder().setSessionId("s").setFrameCount(frames).setImageWidth(100).setImageHeight(100).build()
        return SequenceViewModel(
            scope, info, FrameRepository { null }, ProcessingRepository(scope) { null }, OutlierRepository { null },
            ImageCache(), ExportRepository { null }, HorizonRepository { null },
        )
    }

    private suspend fun until(timeoutMs: Long = 3_000, condition: () -> Boolean): Boolean =
        withTimeoutOrNull(timeoutMs) { while (!condition()) delay(5); true } ?: false

    /** Playback forces scrub, since nothing can be edited while it runs; stopping it puts back what was there. */
    @Test fun stoppingPlaybackRestoresTheModeThatWasBefore() = runBlocking {
        val v = vm(50)
        v.setMode(InteractionMode.EDIT)
        v.playForward()
        assertTrue(until { v.isPlaying.value })
        assertEquals(InteractionMode.SCRUB, v.mode.value)
        v.stopPlayback()
        assertEquals(InteractionMode.EDIT, v.mode.value)
    }

    @Test fun playbackThatRunsToTheEndRestoresTheModeToo() = runBlocking {
        val v = vm(3)
        v.setPlaybackFps(90)
        v.setMode(InteractionMode.GRID)
        v.playForward()
        assertTrue(until { !v.isPlaying.value }, "playback never stopped at the end")
        assertEquals(2, v.currentIndex.value)
        assertEquals(InteractionMode.GRID, v.mode.value)
    }

    /** Space is the play button, which always plays forward, even from a reverse playback (that stops it, as a toggle). */
    @Test fun thePlayButtonAlwaysMeansForward() = runBlocking {
        val v = vm(50)
        v.setCurrentIndex(40)
        v.playReverse()
        assertTrue(until { v.isPlaying.value })
        assertEquals(VideoPlayMode.REVERSE, v.playMode.value)

        v.playForward()               // the play button, pressed while playing in reverse
        assertFalse(v.isPlaying.value)
        assertEquals(VideoPlayMode.FORWARD, v.playMode.value)

        v.playForward()
        assertTrue(until { v.isPlaying.value })
        assertEquals(VideoPlayMode.FORWARD, v.playMode.value)
        v.stopPlayback()
    }

    /** "Preview first" starts playing; if it already is, it must not stop it. */
    @Test fun startingPlaybackForwardNeverTogglesItOff() = runBlocking {
        val v = vm(50)
        v.startPlaybackForward()
        assertTrue(until { v.isPlaying.value })
        v.startPlaybackForward()
        assertTrue(v.isPlaying.value, "starting playback again stopped it")
        v.stopPlayback()
    }

    @Test fun aSingleFrameCannotPlay() {
        val v = vm(1)
        v.playForward()
        assertFalse(v.isPlaying.value)
        assertEquals(InteractionMode.SCRUB, v.mode.value)
    }

    @Test fun aFrameIsGivenTheTimeItsSlotHasLeft() {
        assertEquals(33, frameDelayMs(fps = 30, spentMs = 0))
        assertEquals(23, frameDelayMs(fps = 30, spentMs = 10))
        assertEquals(0, frameDelayMs(fps = 30, spentMs = 33))
        assertEquals(0, frameDelayMs(fps = 30, spentMs = 500), "a slow frame is followed at once, never by a negative sleep")
        assertEquals(1000, frameDelayMs(fps = 1, spentMs = 0))
        assertNotNull(frameDelayMs(fps = 0, spentMs = 0), "a rate of zero must not divide by zero")
    }
}
