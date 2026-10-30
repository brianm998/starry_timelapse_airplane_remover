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
import com.star.proto.Envelope
import com.star.proto.FindFrameOutliersRequest
import com.star.proto.FrameInfo
import com.star.proto.ReprocessingType
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
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * L7 of the parity plan: "Find outliers for this frame" and "Re-process this frame from the start" are done inline, as macOS does them, not as
 * a processing run. The client asks the daemon for `Frame.FindOutliers` and never begins a run (so the processing screen does not come up),
 * and the frame takes the counts the daemon answers with.
 */
class InlineFindOutliersTest {
    private val failures = CopyOnWriteArrayList<Throwable>()
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default + CoroutineExceptionHandler { _, e -> failures += e })
    private val clientToDaemonSink = PipedOutputStream()
    private val daemonIn = PipedInputStream(clientToDaemonSink, 1 shl 16)
    private val daemonToClientSink = PipedOutputStream()
    private val clientIn = PipedInputStream(daemonToClientSink, 1 shl 16)
    private val conn = StdioConnection(clientIn, clientToDaemonSink, scope)

    /** Every method the client called, in order, and the `Frame.FindOutliers` requests among them. */
    private val methods = CopyOnWriteArrayList<String>()
    private val asked = CopyOnWriteArrayList<FindFrameOutliersRequest>()

    /** What the daemon answers a find with; the tests change it. */
    @Volatile private var answer: FrameInfo = FrameInfo.newBuilder().setFrameIndex(2).setNumUndecidedOutliers(5).setOutliersLoaded(true).build()
    @Volatile private var refuse: String? = null

    @AfterTest fun tearDown() {
        conn.close()
        scope.cancel()
        runCatching { clientToDaemonSink.close() }
        runCatching { daemonToClientSink.close() }
    }

    private fun startDaemon() {
        conn.start()
        Thread {
            try {
                while (true) {
                    val env = Envelope.parseFrom(Framing.readFrame(daemonIn) ?: break)
                    if (env.kind != Envelope.Kind.REQUEST) continue
                    methods += env.method
                    val reply = when {
                        env.method == "Frame.FindOutliers" && refuse != null ->
                            Envelope.newBuilder().setId(env.id).setKind(Envelope.Kind.ERROR).setError(refuse!!).setErrorCode(500)
                        env.method == "Frame.FindOutliers" -> {
                            asked += FindFrameOutliersRequest.parseFrom(env.payload)
                            Envelope.newBuilder().setId(env.id).setKind(Envelope.Kind.RESPONSE).setPayload(ByteString.copyFrom(answer.toByteArray()))
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

    private val errors = CopyOnWriteArrayList<String>()

    private fun vm(): SequenceViewModel {
        val info = SessionInfo.newBuilder().setSessionId("s").setFrameCount(5).setImageWidth(100).setImageHeight(100).build()
        val v = SequenceViewModel(
            scope, info, FrameRepository { StarClient(conn) }, ProcessingRepository(scope) { null },
            OutlierRepository { null }, ImageCache(), ExportRepository { null }, HorizonRepository { null },
            onError = { errors += it },
        )
        v.setCurrentIndex(2)
        return v
    }

    private suspend fun until(timeoutMs: Long = 3_000, condition: () -> Boolean): Boolean =
        withTimeoutOrNull(timeoutMs) { while (!condition()) delay(5); true } ?: false

    @Test fun findingOutliersAsksTheDaemonInlineKeepingTheFramesWorkAndBeginsNoRun() {
        runBlocking {
            startDaemon()
            val v = vm()

            v.findOutliersCurrent()

            assertTrue(until { asked.isNotEmpty() }, "the daemon was not asked")
            assertEquals(2, asked[0].frameIndex)
            assertFalse(asked[0].startOver, "finding the outliers again keeps what the frame has")
            assertTrue(until { v.frameInfoFlow(2).value?.numUndecidedOutliers == 5 }, "the frame did not take the daemon's counts")
            assertTrue(until { !v.rendering.value }, "the busy flag was left on")
            assertTrue(methods.none { it.startsWith("Processing.") }, "no run is begun: $methods")
            assertTrue(failures.isEmpty(), "$failures")
            assertTrue(errors.isEmpty(), "$errors")
        }
    }

    @Test fun reprocessingStartsOverWithWhatTheRightPanelSays() {
        runBlocking {
            startDaemon()
            val v = vm()
            v.setReprocessType(ReprocessingType.REPROCESS_ALIGNMENT)

            v.reprocessCurrent()

            assertTrue(until { asked.isNotEmpty() }, "the daemon was not asked")
            assertTrue(asked[0].startOver)
            assertEquals(ReprocessingType.REPROCESS_ALIGNMENT, asked[0].reprocessingType, "the panel's choice of what to throw away")
            assertTrue(until { !v.rendering.value })
            assertTrue(methods.none { it.startsWith("Processing.") }, "no run is begun: $methods")
        }
    }

    @Test fun aRefusalIsShownToTheUserAndLeavesTheButtonsFree() {
        runBlocking {
            startDaemon()
            refuse = "a processing run is going; stop it, or wait for it, first"
            val v = vm()

            v.findOutliersCurrent()

            assertTrue(until { errors.isNotEmpty() }, "the refusal was not shown")
            assertTrue(errors[0].contains("processing run is going"), errors.toString())
            assertTrue(until { !v.rendering.value }, "the busy flag was left on")
        }
    }
}
