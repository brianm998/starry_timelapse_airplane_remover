package com.star.desktop.data

import com.star.desktop.engine.StarClient
import com.star.desktop.engine.StarRpcException
import com.star.proto.CleanMethod
import com.star.proto.FrameInfo
import com.star.proto.FrameViewMode
import com.star.proto.ImageRef
import com.star.proto.PreviewSize

/**
 * Per-frame queries. Previews/label images come back as filesystem paths (`ImageRef`); the client
 * reads those via [ImageCache]. `stard` returns an ERROR for a preview/label that isn't generated
 * yet (processing writes previews only after a frame completes) — those are surfaced as `null` here
 * rather than thrown, so the UI can show a placeholder and retry as processing progresses.
 */
class FrameRepository(private val clientProvider: () -> StarClient?) {

    private fun c(): StarClient = clientProvider() ?: throw StarRpcException(-1, "engine not connected")

    suspend fun info(sessionId: String, frameIndex: Int): FrameInfo = c().getFrame(sessionId, frameIndex)

    /** Preview image path for [viewMode], or null if not generated yet. */
    suspend fun previewPath(
        sessionId: String, frameIndex: Int, viewMode: FrameViewMode, size: PreviewSize = PreviewSize.PREVIEW_SIZE_PREVIEW,
    ): ImageRef? =
        notReadyToNull { c().getFramePreview(sessionId, frameIndex, viewMode, size) }

    /** 16-bit outlier-id label image path, or null if outliers aren't loaded yet. */
    suspend fun labelImage(sessionId: String, frameIndex: Int): ImageRef? =
        notReadyToNull { c().getOutlierLabelImage(sessionId, frameIndex) }

    /** The mask of the frame's trashed groups (8-bit, 255 = trash), or null if outliers aren't loaded. */
    suspend fun trashImage(sessionId: String, frameIndex: Int): ImageRef? =
        notReadyToNull { c().getOutlierTrashImage(sessionId, frameIndex) }

    suspend fun setCleanMethod(sessionId: String, frameIndex: Int, cleanMethod: CleanMethod): FrameInfo =
        c().setFrameCleanMethod(sessionId, frameIndex, cleanMethod)

    private inline fun <T> notReadyToNull(block: () -> T): T? =
        try {
            block()
        } catch (e: StarRpcException) {
            null // "preview not yet generated" / "outliers not yet loaded"
        }
}
