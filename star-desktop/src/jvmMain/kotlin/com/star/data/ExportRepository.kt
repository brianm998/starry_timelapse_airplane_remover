package com.star.data

import com.star.engine.StarClient
import com.star.proto.*
import kotlinx.coroutines.flow.Flow

/** Render sequence and export video operations. */
class ExportRepository(private val client: StarClient) {

    fun renderSequence(sessionId: String): Flow<ProgressEvent> = client.renderSequence(sessionId)

    fun exportVideo(
        sessionId: String,
        outputVideoPath: String = "",
        settings: VideoEncodeSettings = VideoEncodeSettings.getDefaultInstance(),
    ): Flow<ProgressEvent> = client.exportVideo(sessionId, outputVideoPath, settings)

    suspend fun getVideoCapabilities(): VideoCapabilities = client.getVideoCapabilities()
}
