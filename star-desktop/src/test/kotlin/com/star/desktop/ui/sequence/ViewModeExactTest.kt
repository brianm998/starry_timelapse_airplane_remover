package com.star.desktop.ui.sequence

import com.star.desktop.data.ExportRepository
import com.star.desktop.data.FrameRepository
import com.star.desktop.data.HorizonRepository
import com.star.desktop.data.ImageCache
import com.star.desktop.data.OutlierRepository
import com.star.desktop.data.ProcessingRepository
import com.star.desktop.engine.Framing
import com.star.desktop.engine.StarClient
import com.star.desktop.engine.StdioConnection
import com.star.desktop.i18n.Strings
import com.star.desktop.domain.ViewModes
import com.star.proto.Envelope
import com.star.proto.FrameViewMode
import com.star.proto.GetFramePreviewRequest
import com.star.proto.SessionInfo
import kotlinx.coroutines.CoroutineExceptionHandler
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeoutOrNull
import java.io.PipedInputStream
import java.io.PipedOutputStream
import java.util.concurrent.CopyOnWriteArrayList
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Q1 of the parity plan: a frame with no picture in the view mode that is showing says "image not found", as the macOS gui does. The
 * desktop used to fall back through the processed frame, the original, the subtraction and the validation image, so "final" on a frame
 * that was not processed showed the original and nothing said it was not the final.
 */
class ViewModeExactTest {
    private val failures = CopyOnWriteArrayList<Throwable>()
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default + CoroutineExceptionHandler { _, e -> failures += e })
    private val clientToDaemonSink = PipedOutputStream()
    private val daemonIn = PipedInputStream(clientToDaemonSink, 1 shl 16)
    private val daemonToClientSink = PipedOutputStream()
    private val clientIn = PipedInputStream(daemonToClientSink, 1 shl 16)
    private val conn = StdioConnection(clientIn, clientToDaemonSink, scope)
    private val asked = CopyOnWriteArrayList<GetFramePreviewRequest>()

    @BeforeTest fun english() = Strings.setOverride("en")
    @AfterTest fun tearDown() {
        Strings.setOverride(null)
        conn.close()
        scope.cancel()
        runCatching { clientToDaemonSink.close() }
        runCatching { daemonToClientSink.close() }
    }

    /** A daemon that has no picture of anything: every request is an error, and the previews asked for are kept. */
    private fun startDaemonWithNoPictures() {
        conn.start()
        Thread {
            try {
                while (true) {
                    val env = Envelope.parseFrom(Framing.readFrame(daemonIn) ?: break)
                    if (env.kind != Envelope.Kind.REQUEST) continue
                    if (env.method == "Frame.GetPreview") asked += GetFramePreviewRequest.parseFrom(env.payload)
                    val reply = Envelope.newBuilder().setId(env.id).setKind(Envelope.Kind.ERROR).setError("preview not yet generated").setErrorCode(404).build()
                    synchronized(daemonToClientSink) { Framing.writeFrame(daemonToClientSink, reply.toByteArray()) }
                }
            } catch (_: Throwable) {
                // pipe closed
            }
        }.apply { isDaemon = true; start() }
    }

    private fun vm(): SequenceViewModel {
        val info = SessionInfo.newBuilder().setSessionId("s").setFrameCount(5).setImageWidth(100).setImageHeight(100).build()
        return SequenceViewModel(
            scope, info, FrameRepository { StarClient(conn) }, ProcessingRepository(scope) { null },
            OutlierRepository { null }, ImageCache(), ExportRepository { null }, HorizonRepository { null },
        )
    }

    private suspend fun until(timeoutMs: Long = 3_000, condition: () -> Boolean): Boolean =
        withTimeoutOrNull(timeoutMs) { while (!condition()) delay(5); true } ?: false

    @Test fun aModeTheFrameHasNoPictureOfIsAskedForAloneAndShowsAsNotFound() = runBlocking {
        startDaemonWithNoPictures()
        val v = vm()
        v.setViewMode(FrameViewMode.VIEW_PROCESSED)
        assertTrue(until { asked.any { it.viewMode == FrameViewMode.VIEW_PROCESSED } }, "the final frame was never asked for")
        delay(300)                       // a fallback would have gone on to ask for the others
        val modes = asked.map { it.viewMode }.toSet()
        assertTrue(modes.all { it == FrameViewMode.VIEW_PROCESSED || it == FrameViewMode.VIEW_ORIGINAL }, "asked for $modes")
        assertFalse(v.previewAvailable.value, "the placeholder says the picture is not there")
        assertNull(v.currentPreview.value)
        assertTrue(failures.isEmpty(), "$failures")
    }

    @Test fun thePlaceholderNamesTheModeInTheUsersLanguage() {
        assertEquals("final processed frame image not found for this frame", imageNotFoundText(FrameViewMode.VIEW_PROCESSED))
        assertEquals("star aligned frame image not found for this frame", imageNotFoundText(FrameViewMode.VIEW_STAR_ALIGNED))
        val english = imageNotFoundText(FrameViewMode.VIEW_PROCESSED)
        Strings.setOverride("de")
        val german = imageNotFoundText(FrameViewMode.VIEW_PROCESSED)
        assertNotEquals(english, german)
        assertFalse(german.contains("view_mode.") || german.contains("ui.image_not_found"), german)
        assertTrue(ViewModes.longName(FrameViewMode.VIEW_PROCESSED).let { german.contains(it) }, "the German name of the mode is in the line")
    }
}
