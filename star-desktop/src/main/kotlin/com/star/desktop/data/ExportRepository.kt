package com.star.desktop.data

import com.star.desktop.i18n.localized
import com.star.desktop.engine.StarClient
import com.star.desktop.engine.StarRpcException
import com.star.proto.ProgressEvent
import com.star.proto.VideoCapabilities
import com.star.proto.VideoEncodeSettings
import kotlinx.coroutines.flow.Flow

/**
 * Render/export operations. `Export.*` streams share the daemon's single per-session progress slot
 * with `Processing.StreamProgress`, so callers must not run an export while the processing
 * subscription is live (the caller serializes them).
 */
class ExportRepository(private val clientProvider: () -> StarClient?) {

    private fun c(): StarClient = clientProvider() ?: throw StarRpcException(-1, localized("ui.engine_not_connected"))

    /** The codec→encoder→{pixel format, muxer} validity graph for the Render Video dialog. */
    suspend fun capabilities(): VideoCapabilities = c().getVideoCapabilities()

    /** Where the video would go for [muxer], before it is rendered: the file name the dialog shows. */
    suspend fun defaultVideoPath(sessionId: String, muxer: String): String = c().getDefaultVideoPath(sessionId, muxer)

    fun renderSequence(sessionId: String): Flow<ProgressEvent> = c().renderSequence(sessionId)

    fun exportVideo(sessionId: String, outputPath: String, settings: VideoEncodeSettings): Flow<ProgressEvent> =
        c().exportVideo(sessionId, outputPath, settings)
}
