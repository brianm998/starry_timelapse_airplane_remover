package com.star.desktop.engine

import com.google.protobuf.ByteString
import com.star.proto.Envelope
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.take
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import java.io.PipedInputStream
import java.io.PipedOutputStream
import java.util.concurrent.CopyOnWriteArrayList
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue

/**
 * Drives [StdioConnection] against an in-process "mock daemon" wired through piped streams,
 * exercising the multiplexer the way the real `stard` would: unary round-trips, ERROR mapping,
 * server-streaming, interleaving of unary + stream on one pipe, transport CANCEL, and EOF teardown.
 */
class StdioConnectionTest {

    // client.output → daemon reads
    private val clientToDaemonSink = PipedOutputStream()
    private val daemonIn = PipedInputStream(clientToDaemonSink, 1 shl 16)
    // daemon writes → client.input
    private val daemonToClientSink = PipedOutputStream()
    private val clientIn = PipedInputStream(daemonToClientSink, 1 shl 16)

    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())
    private val conn = StdioConnection(clientIn, clientToDaemonSink, scope)
    private val client = StarClient(conn)

    /** Frames the daemon received (for asserting CANCEL etc.). */
    private val received = CopyOnWriteArrayList<Envelope>()
    private var daemonThread: Thread? = null

    private fun startDaemon(handle: (Envelope) -> Unit) {
        conn.start()
        daemonThread = Thread {
            try {
                while (true) {
                    val frame = Framing.readFrame(daemonIn) ?: break
                    val env = Envelope.parseFrom(frame)
                    received += env
                    handle(env)
                }
            } catch (_: Throwable) {
                // pipe closed
            }
        }.apply { isDaemon = true; start() }
    }

    @Synchronized
    private fun daemonSend(env: Envelope) = Framing.writeFrame(daemonToClientSink, env.toByteArray())

    private fun response(id: Long, payload: ByteArray) =
        Envelope.newBuilder().setId(id).setKind(Envelope.Kind.RESPONSE).setPayload(ByteString.copyFrom(payload)).build()

    private fun error(id: Long, code: Int, msg: String) =
        Envelope.newBuilder().setId(id).setKind(Envelope.Kind.ERROR).setErrorCode(code).setError(msg).build()

    private fun streamItem(id: Long, payload: ByteArray) =
        Envelope.newBuilder().setId(id).setKind(Envelope.Kind.STREAM_ITEM).setPayload(ByteString.copyFrom(payload)).build()

    private fun streamEnd(id: Long) =
        Envelope.newBuilder().setId(id).setKind(Envelope.Kind.STREAM_END).build()

    @AfterTest
    fun tearDown() {
        conn.close()
        daemonThread?.interrupt()
        runCatching { clientToDaemonSink.close() }
        runCatching { daemonToClientSink.close() }
    }

    @Test
    fun unaryRoundTrip() = runBlocking {
        startDaemon { env -> if (env.kind == Envelope.Kind.REQUEST) daemonSend(response(env.id, env.payload.toByteArray())) }
        withTimeout(5000) {
            val resp = conn.sendUnary("Echo", byteArrayOf(7, 8, 9))
            assertContentEquals(byteArrayOf(7, 8, 9), resp.payload.toByteArray())
        }
    }

    @Test
    fun errorMapsToException() = runBlocking {
        startDaemon { env -> if (env.kind == Envelope.Kind.REQUEST) daemonSend(error(env.id, 404, "not found")) }
        withTimeout(5000) {
            val ex = assertFailsWith<StarRpcException> { conn.sendUnary("Missing", ByteArray(0)) }
            assertEquals(404, ex.code)
        }
    }

    @Test
    fun serverStreamItemsThenEnd() = runBlocking {
        startDaemon { env ->
            if (env.kind == Envelope.Kind.REQUEST) {
                daemonSend(streamItem(env.id, byteArrayOf(1)))
                daemonSend(streamItem(env.id, byteArrayOf(2)))
                daemonSend(streamItem(env.id, byteArrayOf(3)))
                daemonSend(streamEnd(env.id))
            }
        }
        withTimeout(5000) {
            val items = conn.sendStream("Stream", ByteArray(0)).toList()
            assertEquals(listOf(1, 2, 3), items.map { it.payload.toByteArray()[0].toInt() })
        }
    }

    @Test
    fun interleavedUnaryAndStream() = runBlocking {
        startDaemon { env ->
            if (env.kind != Envelope.Kind.REQUEST) return@startDaemon
            when (env.method) {
                "Stream" -> scope.launch {
                    daemonSend(streamItem(env.id, byteArrayOf(10)))
                    delay(30)
                    daemonSend(streamItem(env.id, byteArrayOf(20)))
                    daemonSend(streamEnd(env.id))
                }
                "Unary" -> scope.launch {
                    delay(15)
                    daemonSend(response(env.id, byteArrayOf(99)))
                }
            }
        }
        withTimeout(5000) {
            val streamDeferred = async { conn.sendStream("Stream", ByteArray(0)).toList() }
            val unary = conn.sendUnary("Unary", ByteArray(0))
            assertEquals(99, unary.payload.toByteArray()[0].toInt())
            val items = streamDeferred.await()
            assertEquals(listOf(10, 20), items.map { it.payload.toByteArray()[0].toInt() })
        }
    }

    @Test
    fun cancellingStreamSendsCancel() = runBlocking {
        startDaemon { env ->
            // Emit one item then go quiet so the collector must cancel to stop.
            if (env.kind == Envelope.Kind.REQUEST) daemonSend(streamItem(env.id, byteArrayOf(1)))
        }
        withTimeout(5000) {
            // take(1) cancels the upstream after the first item → connection sends CANCEL.
            val first = conn.sendStream("Stream", ByteArray(0)).take(1).toList()
            assertEquals(1, first.size)
            // Give the CANCEL frame time to reach the daemon.
            var sawCancel = false
            repeat(50) {
                if (received.any { it.kind == Envelope.Kind.CANCEL }) { sawCancel = true; return@repeat }
                delay(20)
            }
            assertTrue(sawCancel, "daemon should have received a CANCEL frame")
        }
    }

    @Test
    fun eofTearsDownPendingCalls() = runBlocking {
        startDaemon { /* never responds */ }
        withTimeout(5000) {
            val call = async { runCatching { conn.sendUnary("NeverAnswered", ByteArray(0)) } }
            delay(50)
            daemonToClientSink.close() // daemon stdout EOF
            val result = call.await()
            assertTrue(result.isFailure, "pending call should fail when the connection closes")
            assertTrue(conn.isClosed)
        }
    }
}
