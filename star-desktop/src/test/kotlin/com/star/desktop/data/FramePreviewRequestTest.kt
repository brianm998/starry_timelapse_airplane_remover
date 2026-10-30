package com.star.desktop.data

import com.google.protobuf.ByteString
import com.star.desktop.engine.Framing
import com.star.desktop.engine.StarClient
import com.star.desktop.engine.StdioConnection
import com.star.proto.Envelope
import com.star.proto.FrameViewMode
import com.star.proto.GetFramePreviewRequest
import com.star.proto.ImageRef
import com.star.proto.PreviewSize
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import java.io.PipedInputStream
import java.io.PipedOutputStream
import java.util.concurrent.CopyOnWriteArrayList
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * Q3 of the parity plan: an aligned image the default mode never wrote is built by the daemon only when the request says to
 * (`build_if_missing`), which is for the frame the user is looking at and not for a thumbnail or a prefetch. This checks what goes on the
 * wire from [FrameRepository.previewPath], against an in-process daemon that records the requests.
 */
class FramePreviewRequestTest {
    private val clientToDaemonSink = PipedOutputStream()
    private val daemonIn = PipedInputStream(clientToDaemonSink, 1 shl 16)
    private val daemonToClientSink = PipedOutputStream()
    private val clientIn = PipedInputStream(daemonToClientSink, 1 shl 16)
    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())
    private val conn = StdioConnection(clientIn, clientToDaemonSink, scope)
    private val frames = FrameRepository { StarClient(conn) }
    private val requests = CopyOnWriteArrayList<GetFramePreviewRequest>()

    private fun startDaemon() {
        conn.start()
        Thread {
            try {
                while (true) {
                    val env = Envelope.parseFrom(Framing.readFrame(daemonIn) ?: break)
                    if (env.kind != Envelope.Kind.REQUEST || env.method != "Frame.GetPreview") continue
                    requests += GetFramePreviewRequest.parseFrom(env.payload)
                    val ref = ImageRef.newBuilder().setPath("/x/p.jpg").build()
                    val reply = Envelope.newBuilder().setId(env.id).setKind(Envelope.Kind.RESPONSE).setPayload(ByteString.copyFrom(ref.toByteArray())).build()
                    synchronized(daemonToClientSink) { Framing.writeFrame(daemonToClientSink, reply.toByteArray()) }
                }
            } catch (_: Throwable) {
                // pipe closed
            }
        }.apply { isDaemon = true; start() }
    }

    @AfterTest fun tearDown() {
        conn.close()
        runCatching { clientToDaemonSink.close() }
        runCatching { daemonToClientSink.close() }
    }

    @Test fun aRequestBuildsNothingUnlessItSaysSo() = runBlocking {
        startDaemon()
        withTimeout(5000) {
            frames.previewPath("s", 3, FrameViewMode.VIEW_STAR_ALIGNED, PreviewSize.PREVIEW_SIZE_THUMBNAIL)
            frames.previewPath("s", 4, FrameViewMode.VIEW_STAR_ALIGNED)
        }
        assertEquals(2, requests.size)
        assertTrue(requests.none { it.buildIfMissing }, "a thumbnail or a prefetch must not start a warp of the neighbours")
    }

    @Test fun theFrameBeingLookedAtAsksForItToBeBuilt() = runBlocking {
        startDaemon()
        withTimeout(5000) {
            frames.previewPath("s", 3, FrameViewMode.VIEW_EARTH_ALIGNED, buildIfMissing = true)
            frames.previewPath("s", 3, FrameViewMode.VIEW_EARTH_ALIGNED, PreviewSize.PREVIEW_SIZE_ORIGINAL, buildIfMissing = true)
        }
        assertEquals(2, requests.size)
        assertTrue(requests.all { it.buildIfMissing })
        assertEquals(listOf(PreviewSize.PREVIEW_SIZE_PREVIEW, PreviewSize.PREVIEW_SIZE_ORIGINAL), requests.map { it.size })
        assertFalse(requests.any { it.viewMode != FrameViewMode.VIEW_EARTH_ALIGNED })
    }
}
