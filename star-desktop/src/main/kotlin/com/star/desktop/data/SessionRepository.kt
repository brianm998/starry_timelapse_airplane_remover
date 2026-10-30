package com.star.desktop.data

import com.star.desktop.i18n.localized
import com.star.desktop.engine.StarClient
import com.star.desktop.engine.StarRpcException
import com.star.proto.Config
import com.star.proto.ConfigChangePreview
import com.star.proto.OpenProgress
import com.star.proto.KeypointDivisorAdvice
import com.star.proto.SequenceProgress
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
        clientProvider() ?: throw StarRpcException(-1, localized("ui.engine_not_connected"))

    suspend fun openSequence(dir: String, initialConfig: Config = defaultInitialConfig()): SessionInfo =
        client().openSequence(dir, initialConfig).also { _session.value = it }

    suspend fun openConfig(configJsonPath: String): SessionInfo =
        client().openConfig(configJsonPath).also { _session.value = it }

    /** Streams decode progress; the terminal `OpenProgress.done(SessionInfo)` is applied to [session]. */
    fun openVideo(
        videoPath: String,
        initialConfig: Config = defaultInitialConfig(),
        options: com.star.desktop.domain.VideoImportOptions = com.star.desktop.domain.VideoImportOptions(),
    ): Flow<OpenProgress> =
        client().openVideo(
            videoPath, initialConfig, options.format.proto, options.jpegQuality,
            tiffCompression = options.tiffCompression.proto, extractInBackground = options.extractInBackground,
        )

    /** Free bytes on the volume holding [path], as the daemon counts them, or null when it would not say. */
    suspend fun freeSpace(path: String): Long? = client().freeSpace(path).takeIf { it.known }?.availableBytes

    /** What the video's header says, for the import dialog's disk estimate. */
    suspend fun probeVideo(videoPath: String): com.star.proto.ProbeVideoResponse = client().probeVideo(videoPath)

    /** Streams how the frames are coming; the terminal `OpenProgress.done(SessionInfo)` is for the caller to apply with [applySessionInfo]. */
    fun openSequenceStream(dir: String, initialConfig: Config = defaultInitialConfig()): Flow<OpenProgress> =
        client().openSequenceStream(dir, initialConfig)

    fun openConfigStream(configJsonPath: String): Flow<OpenProgress> = client().openConfigStream(configJsonPath)

    /** Apply a `SessionInfo` learned out-of-band (e.g. the terminal item of `openVideo`). */
    fun applySessionInfo(info: SessionInfo) { _session.value = info }

    suspend fun close() {
        _session.value?.let { runCatching { client().closeSession(it.sessionId) } }
        _session.value = null
    }

    /** Forget the current session locally without an RPC (e.g. after the engine died). */
    fun clearLocal() { _session.value = null }

    suspend fun getConfig(): Config = client().getConfig(requireSession())

    suspend fun previewConfigChange(config: Config): ConfigChangePreview = client().previewConfigChange(requireSession(), config)

    suspend fun getKeypointAdvice(): KeypointDivisorAdvice = client().getKeypointAdvice(requireSession())

    suspend fun getProgressSurvey(): SequenceProgress = client().getProgressSurvey(requireSession())

    suspend fun updateConfig(config: Config): Config =
        client().updateConfig(requireSession(), config).also { updated ->
            _session.value = _session.value?.toBuilder()?.setConfig(updated)?.build()
        }

    private fun requireSession(): String =
        sessionId ?: throw StarRpcException(-1, localized("ui.no_session_is_open"))

    companion object {
        /**
         * Default initial config for newly-opened sources.
         *  - Previews + outlier-group files must be enabled here — `stard` only writes previews
         *    during processing when `writeFramePreviewFiles` is set, and `Sequence.UpdateConfig`
         *    cannot change these fields after open.
         *  - Horizon detection starts on, as StarCore's own default does (macOS leaves it so when the first startup
         *    prompt is left alone, e.g. for Advanced); the "does it include a horizon?" answer turns it off.
         *  - The clean method is left at the proto's zero, `CLEAN_AUTOMATIC`, which is StarCore's own default
         *    (`Config.swift`, `.automatic(false)`) and what the macOS gui starts a new sequence with. The startup
         *    removal question, or the Processing Settings sheet, change it; leaving that question with Close keeps
         *    this, in both clients. (This used to be selective, from before the startup question existed.)
         */
        fun defaultInitialConfig(): Config = Config.newBuilder()
            .setWriteFramePreviewFiles(true)
            .setWriteOutlierGroupFiles(true)
            .setHorizonDetectionEnabled(true)
            .build()
    }
}
