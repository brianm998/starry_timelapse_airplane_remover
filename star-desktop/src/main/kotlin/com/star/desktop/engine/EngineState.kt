package com.star.desktop.engine

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import com.star.proto.Warning
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.plus
import kotlinx.coroutines.withTimeoutOrNull

/** Connection lifecycle status surfaced to the UI. */
sealed interface EngineStatus {
    data object Disconnected : EngineStatus
    data object Connecting : EngineStatus
    data class Connected(val daemonVersion: String, val scratchDir: String) : EngineStatus
    data class Failed(val message: String) : EngineStatus
}

/**
 * Owns the `stard` child process, the [StdioConnection], and the typed [StarClient]; performs the
 * `Daemon.Hello` handshake and surfaces connection status.
 *
 * Fixes vs the v1 client: status is held as a [StateFlow] (callers never block in a `collect` to
 * learn the engine came up), and connection death is monitored in its own coroutine. Re-opening the
 * previously-open session after a crash is the caller's job (it holds the session config path);
 * [restart] brings the engine back up and reports `Connected`, then the app re-opens.
 */
class EngineState(
    private val scope: CoroutineScope,
    private val clientVersion: String = "2.0.0",
    private val scratchDir: String = DaemonProcess.defaultScratchDir(),
    private val binaryPath: String = DaemonProcess.resolveStardBinary(),
) {
    private val _status = MutableStateFlow<EngineStatus>(EngineStatus.Disconnected)
    val status: StateFlow<EngineStatus> = _status.asStateFlow()

    /**
     * Warnings the daemon pushed — memory pressure, output it could not write, a disk with no
     * room for the run.
     *
     * Owned here rather than exposed straight off [StdioConnection] because the connection is
     * replaced on every restart, and a collector bound to one instance would go quiet the
     * first time the engine came back. Callers subscribe once and keep receiving.
     */
    private val _warnings = MutableSharedFlow<Warning>(
        extraBufferCapacity = 16,
        onBufferOverflow = BufferOverflow.DROP_OLDEST,
    )
    val warnings: SharedFlow<Warning> = _warnings.asSharedFlow()

    private var process: DaemonProcess? = null
    private var connection: StdioConnection? = null

    /** The typed client, valid only while [status] is [EngineStatus.Connected]. */
    var client: StarClient? = null
        private set

    /** Spawn the daemon, connect, and complete a Hello handshake. Idempotent-ish: returns false on failure. */
    suspend fun start(): Boolean {
        if (_status.value is EngineStatus.Connecting || _status.value is EngineStatus.Connected) return true
        _status.value = EngineStatus.Connecting
        return try {
            val proc = DaemonProcess(binaryPath, scratchDir)
            proc.start(scope)
            // input = daemon stdout (we read), output = daemon stdin (we write).
            // Dedicated connection scope so its IO coroutines aren't tied to a UI scope's lifecycle.
            val conn = StdioConnection(proc.stdout, proc.stdin, scope + SupervisorJob())
            conn.start()
            val cli = StarClient(conn)

            val hello = cli.hello(clientVersion)

            process = proc
            connection = conn
            client = cli
            _status.value = EngineStatus.Connected(hello.daemonVersion, hello.scratchDir)

            // Forward this connection's warnings onto the long-lived flow above.
            scope.launch { conn.warnings.collect { _warnings.tryEmit(it) } }

            // Monitor death in its own coroutine (does not block start()).
            scope.launch {
                val cause = conn.closed.await()
                client = null

                // Prefer what the process itself says over what the broken pipe says. A
                // connection that closes because the daemon was killed reports something
                // generic like "connection closed"; the exit status says *why*, and 137 in
                // particular means the system killed it for memory. Give the process a moment
                // to be reaped — the pipe closes fractionally before the exit status lands.
                var death = proc.deathDescription()
                if (death == null) {
                    withTimeoutOrNull(2_000) {
                        while (death == null) {
                            delay(50)
                            death = proc.deathDescription()
                        }
                    }
                }

                _status.value = EngineStatus.Failed(
                    death ?: cause?.message ?: "the engine stopped unexpectedly",
                )
            }
            true
        } catch (e: Throwable) {
            cleanup()
            _status.value = EngineStatus.Failed(e.message ?: "failed to start engine")
            false
        }
    }

    /** Tear down and bring the engine back up (the app re-opens its session afterward). */
    suspend fun restart(): Boolean {
        shutdown()
        _status.value = EngineStatus.Disconnected
        return start()
    }

    /** Graceful shutdown: ask the daemon to exit, then close the pipe (EOF backstop) and the process. */
    suspend fun shutdown() {
        runCatching { client?.shutdown() }
        cleanup()
        _status.value = EngineStatus.Disconnected
    }

    private fun cleanup() {
        connection?.close()
        process?.destroy()
        connection = null
        process = null
        client = null
    }
}
