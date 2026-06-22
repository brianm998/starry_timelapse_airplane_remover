package com.star.data

import com.star.engine.StarClient
import com.star.proto.*
import kotlinx.coroutines.flow.*

/**
 * Manages the open session lifecycle and config.
 * Wraps Session.* and Sequence.* RPC calls.
 */
class SessionRepository(private val client: StarClient) {

    private val _session = MutableStateFlow<SessionInfo?>(null)
    val session: StateFlow<SessionInfo?> = _session.asStateFlow()

    val sessionId: String get() = _session.value?.sessionId ?: error("no open session")

    suspend fun openSequence(dir: String, initialConfig: Config = Config.getDefaultInstance()): SessionInfo {
        val info = client.openSequence(dir, initialConfig)
        _session.value = info
        return info
    }

    suspend fun openConfig(configJsonPath: String): SessionInfo {
        val info = client.openConfig(configJsonPath)
        _session.value = info
        return info
    }

    fun openVideo(path: String, initialConfig: Config = Config.getDefaultInstance()): Flow<OpenProgress> =
        client.openVideo(path, initialConfig).onEach { progress ->
            // The final item is kind=done and carries the completed SessionInfo.
            if (progress.hasDone()) {
                _session.value = progress.done
            }
        }

    suspend fun close() {
        val id = _session.value?.sessionId ?: return
        client.closeSession(id)
        _session.value = null
    }

    suspend fun getConfig(): Config = client.getConfig(sessionId)

    suspend fun updateConfig(config: Config): Config {
        val updated = client.updateConfig(sessionId, config)
        // Reflect updated config in session info
        _session.value = _session.value?.toBuilder()?.setConfig(updated)?.build()
        return updated
    }
}
