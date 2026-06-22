package com.star.engine

import com.google.protobuf.ByteString
import com.star.proto.Envelope
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.*
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import java.io.InputStream
import java.io.OutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicLong

/**
 * Multiplexer for the stard stdio protobuf protocol.
 *
 * One reader coroutine drains daemon stdout; one writer coroutine drains the outbound Channel
 * onto daemon stdin. Request IDs are AtomicLong. All unary and stream registries use
 * ConcurrentHashMap so they can be accessed from reader/writer concurrently.
 *
 * See CROSS_PLATFORM_DAEMON_DESIGN.md §5.4 and KOTLIN_CLIENT_SPEC.md §2.2.
 */
class StdioConnection(
    private val input: InputStream,
    private val output: OutputStream,
    private val scope: CoroutineScope = CoroutineScope(Dispatchers.IO + SupervisorJob()),
) {
    private val nextId = AtomicLong(1L)

    // Pending unary calls: id → CompletableDeferred<Envelope>
    private val pendingUnary = ConcurrentHashMap<Long, CompletableDeferred<Envelope>>()

    // Pending server-stream calls: id → Channel<Envelope>
    private val pendingStreams = ConcurrentHashMap<Long, Channel<Envelope>>()

    // Outbound frames serialised to bytes; drained by a single writer coroutine.
    private val outboundCh = Channel<ByteArray>(Channel.BUFFERED)

    private var readerJob: Job? = null
    private var writerJob: Job? = null

    /** Call once after construction to start the reader and writer coroutines. */
    fun start() {
        writerJob = scope.launch(Dispatchers.IO) {
            for (data in outboundCh) {
                writeFrame(data)
            }
        }
        readerJob = scope.launch(Dispatchers.IO) {
            runReaderLoop()
        }
    }

    // ---- Internal: reader loop ----

    private suspend fun runReaderLoop() {
        try {
            while (currentCoroutineContext().isActive) {
                val frameData = readFrame() ?: break  // null = EOF
                val env = try {
                    Envelope.parseFrom(frameData)
                } catch (e: Exception) {
                    System.err.println("[StdioConnection] malformed envelope, skipping: $e")
                    continue
                }
                dispatch(env)
            }
        } catch (_: CancellationException) {
            // normal shutdown
        } catch (e: Exception) {
            System.err.println("[StdioConnection] reader error: $e")
        } finally {
            // Connection closed: fail all pending with an error.
            val err = StarRpcException(-1, "connection closed")
            pendingUnary.values.forEach { it.completeExceptionally(err) }
            pendingStreams.values.forEach { ch -> ch.close(err) }
            pendingUnary.clear()
            pendingStreams.clear()
        }
    }

    private fun dispatch(env: Envelope) {
        val id = env.id
        when (env.kind) {
            Envelope.Kind.RESPONSE -> {
                pendingUnary.remove(id)?.complete(env)
            }
            Envelope.Kind.ERROR -> {
                val ex = StarRpcException(env.errorCode, env.error)
                val unaryCompleted = pendingUnary.remove(id)?.completeExceptionally(ex) ?: false
                if (!unaryCompleted) {
                    pendingStreams.remove(id)?.close(ex)
                }
            }
            Envelope.Kind.STREAM_ITEM -> {
                pendingStreams[id]?.trySend(env)
            }
            Envelope.Kind.STREAM_END -> {
                pendingStreams.remove(id)?.close()
            }
            else -> Unit
        }
    }

    // ---- Public API ----

    /**
     * Send a REQUEST and await a single RESPONSE. Throws [StarRpcException] on ERROR.
     */
    suspend fun sendUnary(method: String, payload: ByteArray): Envelope {
        val id = nextId.getAndIncrement()
        val deferred = CompletableDeferred<Envelope>()
        pendingUnary[id] = deferred

        val env = Envelope.newBuilder()
            .setId(id)
            .setKind(Envelope.Kind.REQUEST)
            .setMethod(method)
            .setPayload(ByteString.copyFrom(payload))
            .build()
        outboundCh.send(env.toByteArray())

        return deferred.await()
    }

    /**
     * Send a REQUEST and return a [Flow] of STREAM_ITEMs terminated by STREAM_END.
     * Cancelling the flow sends a transport-level CANCEL to the daemon.
     */
    fun sendStream(method: String, payload: ByteArray): Flow<Envelope> {
        val id = nextId.getAndIncrement()
        val channel = Channel<Envelope>(Channel.BUFFERED)
        pendingStreams[id] = channel

        return flow {
            val env = Envelope.newBuilder()
                .setId(id)
                .setKind(Envelope.Kind.REQUEST)
                .setMethod(method)
                .setPayload(ByteString.copyFrom(payload))
                .build()
            outboundCh.send(env.toByteArray())

            try {
                for (item in channel) {
                    emit(item)
                }
            } catch (e: CancellationException) {
                // Send transport-level CANCEL so the daemon stops producing items.
                sendCancel(id)
                pendingStreams.remove(id)?.close()
                throw e
            } catch (e: StarRpcException) {
                throw e
            }
        }
    }

    private fun sendCancel(id: Long) {
        val env = Envelope.newBuilder()
            .setId(id)
            .setKind(Envelope.Kind.CANCEL)
            .build()
        outboundCh.trySend(env.toByteArray())
    }

    // ---- Framing ----

    private fun readFrame(): ByteArray? {
        val lenBuf = ByteArray(4)
        var read = 0
        while (read < 4) {
            val n = input.read(lenBuf, read, 4 - read)
            if (n < 0) return null
            read += n
        }
        val len = ByteBuffer.wrap(lenBuf).order(ByteOrder.BIG_ENDIAN).int
        if (len < 0) return null  // implausible (corrupt frame)
        if (len == 0) return ByteArray(0)

        val body = ByteArray(len)
        var bodyRead = 0
        while (bodyRead < len) {
            val n = input.read(body, bodyRead, len - bodyRead)
            if (n < 0) return null
            bodyRead += n
        }
        return body
    }

    private fun writeFrame(data: ByteArray) {
        val header = ByteBuffer.allocate(4).order(ByteOrder.BIG_ENDIAN).putInt(data.size).array()
        output.write(header)
        output.write(data)
        output.flush()
    }

    fun close() {
        outboundCh.close()
        readerJob?.cancel()
        writerJob?.cancel()
    }
}

class StarRpcException(val code: Int, message: String) : Exception("RPC error $code: $message")
