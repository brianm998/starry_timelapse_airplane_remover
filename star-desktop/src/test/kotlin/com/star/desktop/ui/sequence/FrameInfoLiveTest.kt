package com.star.desktop.ui.sequence

import com.google.protobuf.ByteString
import com.star.desktop.data.ExportRepository
import com.star.desktop.data.FrameRepository
import com.star.desktop.data.HorizonRepository
import com.star.desktop.data.ImageCache
import com.star.desktop.data.OutlierRepository
import com.star.desktop.data.ProcessingRepository
import com.star.desktop.engine.Framing
import com.star.desktop.engine.StarClient
import com.star.desktop.engine.StdioConnection
import com.star.proto.CleanMethod
import com.star.proto.Envelope
import com.star.proto.FrameInfo
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
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Q11 of the parity plan: the filmstrip and grid cells showed the outlier ticks and clean method they had fetched when the frame's index
 * or state last changed, so an edit made afterwards (Keep All, a decision, a clean-method change) was not on the cell until the state
 * changed. They now draw from [SequenceViewModel.frameInfoFlow], which every edit updates.
 */
class FrameInfoLiveTest {
    private val failures = CopyOnWriteArrayList<Throwable>()
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default + CoroutineExceptionHandler { _, e -> failures += e })
    private val clientToDaemonSink = PipedOutputStream()
    private val daemonIn = PipedInputStream(clientToDaemonSink, 1 shl 16)
    private val daemonToClientSink = PipedOutputStream()
    private val clientIn = PipedInputStream(daemonToClientSink, 1 shl 16)
    private val conn = StdioConnection(clientIn, clientToDaemonSink, scope)

    /** What the daemon says frame 2 looks like now; the tests change it between requests. */
    @Volatile private var frame2: FrameInfo = FrameInfo.newBuilder().setFrameIndex(2).setNumUndecidedOutliers(3).setOutliersLoaded(true).build()

    @AfterTest fun tearDown() {
        conn.close()
        scope.cancel()
        runCatching { clientToDaemonSink.close() }
        runCatching { daemonToClientSink.close() }
    }

    /** `Frame.Get` and `Frame.SetCleanMethod` answer with [frame2]; anything else is an error. */
    private fun startDaemon() {
        conn.start()
        Thread {
            try {
                while (true) {
                    val env = Envelope.parseFrom(Framing.readFrame(daemonIn) ?: break)
                    if (env.kind != Envelope.Kind.REQUEST) continue
                    val reply = when (env.method) {
                        "Frame.Get" -> Envelope.newBuilder().setId(env.id).setKind(Envelope.Kind.RESPONSE).setPayload(ByteString.copyFrom(frame2.toByteArray()))
                        "Frame.SetCleanMethod" -> {
                            val request = com.star.proto.SetFrameCleanMethodRequest.parseFrom(env.payload)
                            frame2 = frame2.toBuilder().setCleanMethod(request.cleanMethod).setNumUndecidedOutliers(0).build()
                            Envelope.newBuilder().setId(env.id).setKind(Envelope.Kind.RESPONSE).setPayload(ByteString.copyFrom(frame2.toByteArray()))
                        }
                        else -> Envelope.newBuilder().setId(env.id).setKind(Envelope.Kind.ERROR).setError("not under test").setErrorCode(404)
                    }.build()
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

    @Test fun aFrameCellFollowsAnEditMadeAfterItWasFetched() = runBlocking {
        startDaemon()
        val v = vm()
        assertNull(v.frameInfoFlow(2).value, "nothing is held until the cell asks")

        v.refreshFrameInfo(2)
        assertEquals(3, v.frameInfoFlow(2).value?.numUndecidedOutliers, "the counts the cell was drawn with")

        // The edit: the frame's clean method is changed, as the grid's context menu or the right panel does.
        v.frameVMFor(2).setCleanMethod(CleanMethod.CLEAN_SELECTIVE)
        assertTrue(until { v.frameInfoFlow(2).value?.cleanMethod == CleanMethod.CLEAN_SELECTIVE }, "the cell's info did not follow the edit")
        assertEquals(0, v.frameInfoFlow(2).value?.numUndecidedOutliers, "the counts came with the edit")
        assertTrue(failures.isEmpty(), "$failures")
    }

    @Test fun aFrameWhoseDataWentStaleIsFetchedAgainAndTheRefreshReplacesWhatWasHeld() = runBlocking {
        startDaemon()
        val v = vm()
        v.refreshFrameInfo(2)
        frame2 = frame2.toBuilder().setNumUndecidedOutliers(0).setNumPositiveOutliers(3).build()
        v.refreshFrameInfo(2)
        assertEquals(3, v.frameInfoFlow(2).value?.numPositiveOutliers)
        assertEquals(0, v.frameInfoFlow(2).value?.numUndecidedOutliers)
        assertTrue(failures.isEmpty(), "$failures")
    }
}
