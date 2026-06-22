package com.star.engine

import com.google.protobuf.ByteString
import com.star.proto.Envelope
import kotlinx.coroutines.*
import java.io.PipedInputStream
import java.io.PipedOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.test.*

/**
 * Transport unit tests — mirrors §8.1 of KOTLIN_CLIENT_SPEC.md.
 * Tests framing round-trip, interleaved unary + stream on one pipe,
 * CANCEL, and stdout EOF handling.
 */
class StdioConnectionTest {

    // Build a fake daemon that echoes frames back to validate the connection machinery.
    private fun makePipeConnection(): Triple<StdioConnection, PipedOutputStream, PipedInputStream> {
        // client reads from clientIn (fed by serverOut)
        // client writes to serverIn (read by test to send fake daemon frames)
        val clientIn = PipedInputStream(4096)
        val serverOut = PipedOutputStream(clientIn)

        val serverIn = PipedInputStream(4096)
        val clientOut = PipedOutputStream(serverIn)

        val conn = StdioConnection(
            input = clientIn,
            output = clientOut,
            scope = CoroutineScope(Dispatchers.IO + SupervisorJob()),
        )
        conn.start()

        return Triple(conn, serverOut, serverIn)
    }

    /** Write a framed Envelope into the pipe from the "daemon" side. */
    private fun writeEnvelope(out: PipedOutputStream, env: Envelope) {
        val bytes = env.toByteArray()
        val header = ByteBuffer.allocate(4).order(ByteOrder.BIG_ENDIAN).putInt(bytes.size).array()
        out.write(header)
        out.write(bytes)
        out.flush()
    }

    @Test
    fun `framing round-trip - unary call returns response`() = runBlocking {
        val (conn, serverOut, serverIn) = makePipeConnection()

        // Simulate daemon: read one REQUEST, send back a RESPONSE.
        val echoJob = launch(Dispatchers.IO) {
            val lenBuf = ByteArray(4)
            var read = 0
            while (read < 4) read += serverIn.read(lenBuf, read, 4 - read)
            val len = ByteBuffer.wrap(lenBuf).order(ByteOrder.BIG_ENDIAN).int
            val bodyBuf = ByteArray(len)
            var br = 0
            while (br < len) br += serverIn.read(bodyBuf, br, len - br)

            val reqEnv = Envelope.parseFrom(bodyBuf)
            assertEquals(Envelope.Kind.REQUEST, reqEnv.kind)

            // Echo back a RESPONSE with the same id.
            val resp = Envelope.newBuilder()
                .setId(reqEnv.id)
                .setKind(Envelope.Kind.RESPONSE)
                .setPayload(ByteString.copyFromUtf8("pong"))
                .build()
            writeEnvelope(serverOut, resp)
        }

        val env = conn.sendUnary("Test.Echo", "ping".toByteArray())
        assertEquals(Envelope.Kind.RESPONSE, env.kind)
        assertEquals("pong", env.payload.toStringUtf8())

        echoJob.join()
        conn.close()
    }

    @Test
    fun `interleaved unary requests complete independently`() = runBlocking {
        val (conn, serverOut, serverIn) = makePipeConnection()

        // Read two requests and respond in reversed order to test that id routing works.
        val echoJob = launch(Dispatchers.IO) {
            fun readOneEnv(): Envelope {
                val lenBuf = ByteArray(4)
                var r = 0
                while (r < 4) r += serverIn.read(lenBuf, r, 4 - r)
                val len = ByteBuffer.wrap(lenBuf).order(ByteOrder.BIG_ENDIAN).int
                val body = ByteArray(len)
                var br = 0
                while (br < len) br += serverIn.read(body, br, len - br)
                return Envelope.parseFrom(body)
            }

            val req1 = readOneEnv()
            val req2 = readOneEnv()

            // Respond to req2 first, then req1 — tests id-based routing.
            writeEnvelope(serverOut, Envelope.newBuilder().setId(req2.id).setKind(Envelope.Kind.RESPONSE)
                .setPayload(ByteString.copyFromUtf8("resp2")).build())
            writeEnvelope(serverOut, Envelope.newBuilder().setId(req1.id).setKind(Envelope.Kind.RESPONSE)
                .setPayload(ByteString.copyFromUtf8("resp1")).build())
        }

        // Send two concurrent unary calls.
        val deferred1 = async { conn.sendUnary("Test.One", ByteArray(0)) }
        val deferred2 = async { conn.sendUnary("Test.Two", ByteArray(0)) }

        val resp1 = deferred1.await()
        val resp2 = deferred2.await()

        assertEquals("resp1", resp1.payload.toStringUtf8())
        assertEquals("resp2", resp2.payload.toStringUtf8())

        echoJob.join()
        conn.close()
    }

    @Test
    fun `server stream delivers items then terminates`() = runBlocking {
        val (conn, serverOut, serverIn) = makePipeConnection()

        val echoJob = launch(Dispatchers.IO) {
            val lenBuf = ByteArray(4)
            var r = 0
            while (r < 4) r += serverIn.read(lenBuf, r, 4 - r)
            val len = ByteBuffer.wrap(lenBuf).order(ByteOrder.BIG_ENDIAN).int
            val body = ByteArray(len)
            var br = 0
            while (br < len) br += serverIn.read(body, br, len - br)
            val req = Envelope.parseFrom(body)

            // Send 3 STREAM_ITEMs then STREAM_END.
            for (i in 1..3) {
                writeEnvelope(serverOut, Envelope.newBuilder()
                    .setId(req.id).setKind(Envelope.Kind.STREAM_ITEM)
                    .setPayload(ByteString.copyFromUtf8("item$i")).build())
            }
            writeEnvelope(serverOut, Envelope.newBuilder()
                .setId(req.id).setKind(Envelope.Kind.STREAM_END).build())
        }

        val collected = mutableListOf<String>()
        conn.sendStream("Test.Stream", ByteArray(0)).collect { env ->
            collected += env.payload.toStringUtf8()
        }

        assertEquals(listOf("item1", "item2", "item3"), collected)
        echoJob.join()
        conn.close()
    }

    @Test
    fun `ERROR envelope throws StarRpcException from unary call`() = runBlocking {
        val (conn, serverOut, serverIn) = makePipeConnection()

        val echoJob = launch(Dispatchers.IO) {
            val lenBuf = ByteArray(4)
            var r = 0
            while (r < 4) r += serverIn.read(lenBuf, r, 4 - r)
            val len = ByteBuffer.wrap(lenBuf).order(ByteOrder.BIG_ENDIAN).int
            val body = ByteArray(len)
            var br = 0
            while (br < len) br += serverIn.read(body, br, len - br)
            val req = Envelope.parseFrom(body)

            writeEnvelope(serverOut, Envelope.newBuilder()
                .setId(req.id).setKind(Envelope.Kind.ERROR)
                .setError("something went wrong").setErrorCode(42).build())
        }

        val ex = assertFailsWith<StarRpcException> {
            conn.sendUnary("Test.Fail", ByteArray(0))
        }
        assertEquals(42, ex.code)
        assertTrue(ex.message!!.contains("something went wrong"))

        echoJob.join()
        conn.close()
    }

    @Test
    fun `stdout EOF causes pending calls to fail`() = runBlocking {
        val (conn, serverOut, _) = makePipeConnection()

        val callJob = launch {
            assertFailsWith<StarRpcException> {
                conn.sendUnary("Test.EOF", ByteArray(0))
            }
        }

        delay(50)  // let the call get registered
        serverOut.close()  // simulate daemon exit
        callJob.join()

        conn.close()
    }
}
