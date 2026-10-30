package com.star.desktop.data

import com.star.desktop.i18n.localized
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

    private fun c(): StarClient = clientProvider() ?: throw StarRpcException(-1, localized("ui.engine_not_connected"))

    suspend fun info(sessionId: String, frameIndex: Int): FrameInfo = c().getFrame(sessionId, frameIndex)

    /** Preview image path for [viewMode], or null if not generated yet. [buildIfMissing]: see [StarClient.getFramePreview]. */
    suspend fun previewPath(
        sessionId: String, frameIndex: Int, viewMode: FrameViewMode, size: PreviewSize = PreviewSize.PREVIEW_SIZE_PREVIEW,
        buildIfMissing: Boolean = false,
    ): ImageRef? =
        // A frame that is not extracted from its video yet is an answer, not a failure: it has no picture, and the placeholder says why.
        notReadyToNull { c().getFramePreview(sessionId, frameIndex, viewMode, size, buildIfMissing) }?.takeUnless { it.notExtracted }

    /** Ask for [viewing] and the frames in [nearby] to be extracted first; a failure is not worth telling anyone (the frames come in order anyway). */
    suspend fun prioritize(sessionId: String, viewing: Int, nearby: List<IntRange>) {
        runCatching { c().prioritizeFrames(sessionId, viewing, nearby) }
    }

    /** How long until [frameIndex] is extracted; null when the engine could not say. */
    suspend fun eta(sessionId: String, frameIndex: Int): com.star.proto.FrameEtaResponse? =
        runCatching { c().getFrameEta(sessionId, frameIndex) }.getOrNull()

    /** 16-bit outlier-id label image path, or null if outliers aren't loaded yet. */
    suspend fun labelImage(sessionId: String, frameIndex: Int): ImageRef? =
        notReadyToNull { c().getOutlierLabelImage(sessionId, frameIndex) }

    /** The mask of the frame's trashed groups (8-bit, 255 = trash), or null if outliers aren't loaded. */
    suspend fun trashImage(sessionId: String, frameIndex: Int): ImageRef? =
        notReadyToNull { c().getOutlierTrashImage(sessionId, frameIndex) }

    suspend fun setCleanMethod(sessionId: String, frameIndex: Int, cleanMethod: CleanMethod): FrameInfo =
        c().setFrameCleanMethod(sessionId, frameIndex, cleanMethod)

    /** Find a frame's outlier groups again inline, with no run (see [StarClient.findFrameOutliers]). */
    suspend fun findOutliers(sessionId: String, frameIndex: Int, startOver: Boolean, type: com.star.proto.ReprocessingType): FrameInfo =
        c().findFrameOutliers(sessionId, frameIndex, startOver, type)

    /** A frame's own neighbour count of [kind], set or (null) taken away; whether a run began is in the answer. */
    suspend fun setNeighborOverride(sessionId: String, frameIndex: Int, kind: com.star.proto.NeighborKind, count: Int?) =
        c().setNeighborOverride(sessionId, frameIndex, kind, count)

    private inline fun <T> notReadyToNull(block: () -> T): T? =
        try {
            block()
        } catch (e: StarRpcException) {
            null // "preview not yet generated" / "outliers not yet loaded"
        }
}
