package com.star.desktop.data

import com.star.desktop.engine.StarClient
import com.star.desktop.engine.StarRpcException
import com.star.proto.CleanMethod
import com.star.proto.Config
import com.star.proto.OpenProgress
import com.star.proto.SessionInfo
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * Owns the open-session lifecycle and config. Holds no StarCore format knowledge — every byte of
 * `config.json`, the temp tree, and outputs is produced by `stard`. The client only drives RPCs.
 */
class SessionRepository(private val clientProvider: () -> StarClient?) {

    private val _session = MutableStateFlow<SessionInfo?>(null)
    val session: StateFlow<SessionInfo?> = _session.asStateFlow()

    val sessionId: String? get() = _session.value?.sessionId

    private fun client(): StarClient =
        clientProvider() ?: throw StarRpcException(-1, "engine not connected")

    suspend fun openSequence(dir: String, initialConfig: Config = defaultInitialConfig()): SessionInfo =
        client().openSequence(dir, initialConfig).also { _session.value = it }

    suspend fun openConfig(configJsonPath: String): SessionInfo =
        client().openConfig(configJsonPath).also { _session.value = it }

    /** Streams decode progress; the terminal `OpenProgress.done(SessionInfo)` is applied to [session]. */
    fun openVideo(videoPath: String, initialConfig: Config = defaultInitialConfig()): Flow<OpenProgress> =
        client().openVideo(videoPath, initialConfig)

    /** Apply a `SessionInfo` learned out-of-band (e.g. the terminal item of `openVideo`). */
    fun applySessionInfo(info: SessionInfo) { _session.value = info }

    suspend fun close() {
        _session.value?.let { runCatching { client().closeSession(it.sessionId) } }
        _session.value = null
    }

    /** Forget the current session locally without an RPC (e.g. after the engine died). */
    fun clearLocal() { _session.value = null }

    suspend fun getConfig(): Config = client().getConfig(requireSession())

    suspend fun updateConfig(config: Config): Config =
        client().updateConfig(requireSession(), config).also { updated ->
            _session.value = _session.value?.toBuilder()?.setConfig(updated)?.build()
        }

    private fun requireSession(): String =
        sessionId ?: throw StarRpcException(-1, "no open session")

    companion object {
        /**
         * Default initial config for newly-opened sources.
         *  - Previews + outlier-group files must be enabled here — `stard` only writes previews
         *    during processing when `writeFramePreviewFiles` is set, and `Sequence.UpdateConfig`
         *    cannot change these fields after open.
         *  - Clean method defaults to **selective**: only `selective`/`automatic(true)` have
         *    `usesOutliers == true`, so this is required for the outlier-editing UX (the app's
         *    centerpiece) to have any outliers to show. The ProcessingSettings dialog can change it.
         */
        fun defaultInitialConfig(): Config = Config.newBuilder()
            .setCleanMethod(CleanMethod.CLEAN_SELECTIVE)
            .setWriteFramePreviewFiles(true)
            .setWriteOutlierGroupFiles(true)
            .build()
    }
}
