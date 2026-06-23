package com.star.desktop.data

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

    private fun c(): StarClient = clientProvider() ?: throw StarRpcException(-1, "engine not connected")

    /** The codec→encoder→{pixel format, muxer} validity graph for the Render Video dialog. */
    suspend fun capabilities(): VideoCapabilities = c().getVideoCapabilities()

    fun renderSequence(sessionId: String): Flow<ProgressEvent> = c().renderSequence(sessionId)

    fun exportVideo(sessionId: String, outputPath: String, settings: VideoEncodeSettings): Flow<ProgressEvent> =
        c().exportVideo(sessionId, outputPath, settings)
}
