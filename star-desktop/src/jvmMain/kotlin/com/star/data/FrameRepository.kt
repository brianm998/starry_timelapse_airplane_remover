package com.star.data

import com.star.engine.StarClient
import com.star.proto.*

/** Per-frame info and preview requests. */
class FrameRepository(private val client: StarClient) {

    suspend fun getInfo(sessionId: String, frameIndex: Int): FrameInfo =
        client.getFrame(sessionId, frameIndex)

    suspend fun getPreview(sessionId: String, frameIndex: Int, viewMode: FrameViewMode): ImageRef =
        client.getFramePreview(sessionId, frameIndex, viewMode)

    suspend fun setCleanMethod(sessionId: String, frameIndex: Int, method: CleanMethod): FrameInfo =
        client.setFrameCleanMethod(sessionId, frameIndex, method)
}
