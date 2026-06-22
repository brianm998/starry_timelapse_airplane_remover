package com.star.engine

import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*

/** Connection status of the stard child process. */
sealed class EngineStatus {
    data object Disconnected : EngineStatus()
    data object Connecting : EngineStatus()
    data class Connected(val daemonVersion: String, val scratchDir: String) : EngineStatus()
    data class Failed(val message: String) : EngineStatus()
}

/**
 * Owns the daemon process lifetime and surfaces connection state.
 *
 * Callers:
 *  - Call [start] once to spawn stard and perform the Hello handshake.
 *  - Observe [status] for connection state changes.
 *  - Access [client] only when status is [EngineStatus.Connected].
 *  - Call [restart] after a crash (stdout EOF / process exit).
 *  - Call [shutdown] on app exit.
 *
 * See KOTLIN_CLIENT_SPEC.md §2.1, §2.2.
 */
class EngineState(
    private val binaryPath: String,
    private val scratchDir: String,
) {
    private val _status = MutableStateFlow<EngineStatus>(EngineStatus.Disconnected)
    val status: StateFlow<EngineStatus> = _status.asStateFlow()

    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())

    private var daemonProcess: DaemonProcess? = null
    private var connection: StdioConnection? = null
    private var _client: StarClient? = null

    /** The typed RPC client; only valid when [status] is [EngineStatus.Connected]. */
    val client: StarClient get() = _client ?: error("Engine not connected")

    /** Spawn stard and complete the Daemon.Hello handshake. */
    suspend fun start() {
        if (_status.value is EngineStatus.Connecting || _status.value is EngineStatus.Connected) return
        _status.value = EngineStatus.Connecting

        try {
            val proc = DaemonProcess(binaryPath, scratchDir)
            proc.start(scope)
            daemonProcess = proc

            val conn = StdioConnection(proc.stdout, proc.stdin, scope)
            conn.start()
            connection = conn

            val starClient = StarClient(conn)
            _client = starClient

            // Daemon.Hello handshake — confirms wire protocol and retrieves scratch dir.
            val hello = starClient.hello(clientVersion = "1.0.0")

            _status.value = EngineStatus.Connected(
                daemonVersion = hello.daemonVersion,
                scratchDir = hello.scratchDir,
            )

            // Monitor for daemon exit.
            scope.launch {
                proc.waitFor()
                if (_status.value is EngineStatus.Connected) {
                    _status.value = EngineStatus.Failed("stard exited unexpectedly")
                }
            }
        } catch (e: Exception) {
            _status.value = EngineStatus.Failed(e.message ?: "unknown error")
            cleanUp()
        }
    }

    /** Re-spawn after a crash. The caller should re-open the last session via Session.OpenConfig. */
    suspend fun restart() {
        cleanUp()
        start()
    }

    /** Graceful shutdown: send Daemon.Shutdown, then close stdin (EOF backstop). */
    suspend fun shutdown() {
        if (_status.value is EngineStatus.Connected) {
            try {
                _client?.shutdown()
            } catch (_: Exception) { /* ignore — we're shutting down */ }
        }
        cleanUp()
        _status.value = EngineStatus.Disconnected
    }

    private fun cleanUp() {
        connection?.close()
        connection = null
        daemonProcess?.destroy()
        daemonProcess = null
        _client = null
    }
}
