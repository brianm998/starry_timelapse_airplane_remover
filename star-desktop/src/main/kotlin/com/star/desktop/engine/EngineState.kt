package com.star.desktop.engine

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.plus

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

            // Monitor death in its own coroutine (does not block start()).
            scope.launch {
                val cause = conn.closed.await()
                client = null
                _status.value = EngineStatus.Failed(cause?.message ?: "engine stopped")
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
