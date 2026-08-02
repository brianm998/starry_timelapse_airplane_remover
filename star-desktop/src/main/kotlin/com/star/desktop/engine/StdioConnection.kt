package com.star.desktop.engine

import com.google.protobuf.ByteString
import com.star.proto.Envelope
import com.star.desktop.util.Log
import com.star.proto.Warning
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.launch
import java.io.InputStream
import java.io.OutputStream
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong

/** An RPC error surfaced to a caller. [code] is the daemon's `error_code` (only 404 is meaningful today). */
class StarRpcException(val code: Int, message: String) : Exception("RPC error $code: $message")

/**
 * Multiplexer for the stard stdio protobuf protocol (design §5.4).
 *
 * One duplex pipe carries everything, so interactive unary calls interleave with long-lived
 * progress streams. A single reader coroutine drains the daemon's stdout and dispatches frames
 * by `id`; a single writer coroutine drains an outbound channel onto the daemon's stdin
 * (the "serialized writer" — nothing else writes stdin).
 *
 * This is a clean reimplementation that fixes the v1 client's transport bugs:
 *  - **Stream registration is atomic at collection time** (inside the cold `Flow`), never at
 *    flow-build time, so an uncollected stream never registers or leaks an id slot.
 *  - **The outbound channel is unbounded**, so `REQUEST`/`CANCEL` enqueues are reliable and never
 *    dropped (v1's `trySend` could silently drop a CANCEL).
 *  - **Per-stream channels are unbounded**, so a slow UI collector can't head-of-line-block the
 *    single reader (which would stall every other multiplexed stream) and items are never dropped.
 *  - **Any frame desync** (truncation, implausible length, unparseable envelope) tears the whole
 *    connection down — failing all pending calls — instead of `continue`-ing on a garbage stream.
 */
class StdioConnection(
    private val input: InputStream,
    private val output: OutputStream,
    private val scope: CoroutineScope = CoroutineScope(Dispatchers.IO + SupervisorJob()),
) {
    private val nextId = AtomicLong(1L)

    private val pendingUnary = ConcurrentHashMap<Long, CompletableDeferred<Envelope>>()
    private val pendingStreams = ConcurrentHashMap<Long, Channel<Envelope>>()

    // Unbounded so a send never blocks the caller and never drops a frame; one writer drains it.
    private val outboundCh = Channel<ByteArray>(Channel.UNLIMITED)

    private val closedFlag = AtomicBoolean(false)

    /** Completes when the connection closes; value is the cause (null = clean EOF). */
    val closed = CompletableDeferred<Throwable?>()

    /**
     * Unsolicited warnings the daemon pushed: memory pressure, output it could not write, a
     * disk with no room. See `Warning` in star.proto.
     *
     * `extraBufferCapacity` with [BufferOverflow.DROP_OLDEST] so emitting never suspends the
     * reader loop — the protocol stream must not be able to stall behind the UI collecting
     * these. Dropping the oldest is right for warnings specifically: if they are arriving
     * faster than the UI reads them, the newest describes the current state.
     */
    private val _warnings = MutableSharedFlow<Warning>(
        extraBufferCapacity = 16,
        onBufferOverflow = BufferOverflow.DROP_OLDEST,
    )
    val warnings: SharedFlow<Warning> = _warnings.asSharedFlow()

    val isClosed: Boolean get() = closedFlag.get()

    private var readerJob: Job? = null
    private var writerJob: Job? = null

    /** Start the reader and writer coroutines. Call once. */
    fun start() {
        writerJob = scope.launch(Dispatchers.IO) {
            try {
                for (data in outboundCh) {
                    Framing.writeFrame(output, data)
                }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Throwable) {
                closeWith(e)
            }
        }
        readerJob = scope.launch(Dispatchers.IO) {
            runReaderLoop()
        }
    }

    private fun runReaderLoop() {
        try {
            while (!closedFlag.get()) {
                val frame = Framing.readFrame(input) ?: break // null = clean EOF at a frame boundary
                val env = Envelope.parseFrom(frame) // throws on desync → torn down below
                dispatch(env)
            }
            closeWith(null)
        } catch (e: CancellationException) {
            closeWith(e)
        } catch (e: Throwable) {
            closeWith(e)
        }
    }

    private fun dispatch(env: Envelope) {
        val id = env.id
        when (env.kind) {
            Envelope.Kind.RESPONSE -> pendingUnary.remove(id)?.complete(env)
            Envelope.Kind.ERROR -> {
                val ex = StarRpcException(env.errorCode, env.error)
                val unary = pendingUnary.remove(id)
                if (unary != null) {
                    unary.completeExceptionally(ex)
                } else {
                    pendingStreams.remove(id)?.close(ex)
                }
            }
            // Unbounded channel → trySend only fails if the stream was already torn down; safe to drop then.
            Envelope.Kind.STREAM_ITEM -> pendingStreams[id]?.trySend(env)
            Envelope.Kind.STREAM_END -> pendingStreams.remove(id)?.close()
            // Unsolicited, no id, no response. `tryEmit` rather than `emit`: this runs on the
            // single reader coroutine, and suspending here would stall every multiplexed
            // stream behind whatever is collecting warnings.
            Envelope.Kind.NOTIFICATION -> {
                if (env.method == "Star.Warning") {
                    runCatching { Warning.parseFrom(env.payload) }
                        .onSuccess { _warnings.tryEmit(it) }
                        .onFailure { Log.w("Engine") { "unparseable Star.Warning notification" } }
                }
                // Any other notification method is ignored on purpose — a client that does not
                // understand a notification must keep working, which is what let this be added
                // without a protocol version bump.
            }
            // The daemon never originates REQUEST/CANCEL.
            else -> Unit
        }
    }

    // ---- Public API ----

    /** Send a REQUEST and await its single RESPONSE. Throws [StarRpcException] on ERROR or close. */
    suspend fun sendUnary(method: String, payload: ByteArray): Envelope {
        val id = nextId.getAndIncrement()
        val deferred = CompletableDeferred<Envelope>()
        pendingUnary[id] = deferred
        try {
            enqueue(request(id, method, payload))
            return deferred.await()
        } catch (e: CancellationException) {
            sendCancel(id)
            throw e
        } finally {
            pendingUnary.remove(id)
        }
    }

    /**
     * Send a REQUEST and return a cold [Flow] of STREAM_ITEM envelopes terminated by STREAM_END.
     * Registration + REQUEST happen at collection start; cancelling the collector sends a
     * transport-level CANCEL so the daemon stops producing.
     */
    fun sendStream(method: String, payload: ByteArray): Flow<Envelope> = flow {
        val id = nextId.getAndIncrement()
        val channel = Channel<Envelope>(Channel.UNLIMITED)
        pendingStreams[id] = channel // register BEFORE the request can be answered
        try {
            enqueue(request(id, method, payload))
            for (env in channel) {
                emit(env)
            }
            // Channel closed normally → STREAM_END. Closed with cause → loop throws StarRpcException.
        } catch (e: CancellationException) {
            sendCancel(id)
            throw e
        } finally {
            pendingStreams.remove(id)?.close()
        }
    }

    /** Send a transport-level CANCEL for [id] (distinct from `Processing.Cancel`, which cancels the job). */
    fun sendCancel(id: Long) {
        if (closedFlag.get()) return
        val env = Envelope.newBuilder()
            .setId(id)
            .setKind(Envelope.Kind.CANCEL)
            .build()
        outboundCh.trySend(env.toByteArray()) // unbounded: only fails if already closed
    }

    fun close() = closeWith(null)

    // ---- Internals ----

    private fun request(id: Long, method: String, payload: ByteArray): Envelope =
        Envelope.newBuilder()
            .setId(id)
            .setKind(Envelope.Kind.REQUEST)
            .setMethod(method)
            .setPayload(ByteString.copyFrom(payload))
            .build()

    private fun enqueue(env: Envelope) {
        if (outboundCh.trySend(env.toByteArray()).isFailure) {
            throw StarRpcException(-1, "connection closed")
        }
    }

    private fun closeWith(cause: Throwable?) {
        if (!closedFlag.compareAndSet(false, true)) return
        val ex = cause as? StarRpcException ?: StarRpcException(-1, cause?.message ?: "connection closed")
        pendingUnary.values.forEach { it.completeExceptionally(ex) }
        pendingStreams.values.forEach { it.close(ex) }
        pendingUnary.clear()
        pendingStreams.clear()
        outboundCh.close()
        readerJob?.cancel()
        writerJob?.cancel()
        closed.complete(cause)
    }
}
