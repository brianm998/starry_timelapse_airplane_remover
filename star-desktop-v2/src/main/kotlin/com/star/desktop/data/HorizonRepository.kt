package com.star.desktop.data

import com.star.desktop.engine.StarClient
import com.star.desktop.engine.StarRpcException
import com.star.proto.GetHorizonOverlayResponse
import com.star.proto.GetReferenceHorizonResponse
import com.star.proto.HorizonColumns
import com.star.proto.ProgressEvent
import com.star.proto.SetReferenceHorizonRequest
import com.star.proto.SetReferenceHorizonResponse
import kotlinx.coroutines.flow.Flow

/**
 * Reference-horizon painting. The painted line is sent as per-column horizon-Y in IMAGE space
 * (`-1` = unpainted/all-sky); the daemon owns the on-disk mask format/location.
 */
class HorizonRepository(private val clientProvider: () -> StarClient?) {

    private fun c(): StarClient = clientProvider() ?: throw StarRpcException(-1, "engine not connected")

    suspend fun setReference(
        sessionId: String,
        frameIndex: Int,
        horizonYImageSpace: List<Int>,
        imageWidth: Int,
        imageHeight: Int,
        setStaticReference: Boolean,
    ): SetReferenceHorizonResponse {
        val cols = HorizonColumns.newBuilder()
            .setSpaceWidth(imageWidth)
            .setSpaceHeight(imageHeight)
            .addAllHorizonY(horizonYImageSpace)
            .build()
        val req = SetReferenceHorizonRequest.newBuilder()
            .setSessionId(sessionId)
            .setFrameIndex(frameIndex)
            .setColumns(cols)
            .setSetStaticReference(setStaticReference)
            .build()
        return c().setReferenceHorizon(req)
    }

    suspend fun getReference(sessionId: String, frameIndex: Int): GetReferenceHorizonResponse? =
        try {
            c().getReferenceHorizon(sessionId, frameIndex)
        } catch (e: StarRpcException) {
            null
        }

    suspend fun clearReference(sessionId: String, frameIndex: Int, clearGlobal: Boolean) {
        runCatching { c().clearReferenceHorizon(sessionId, frameIndex, clearGlobal) }
    }

    fun reprocess(sessionId: String, editedFrames: List<Int>): Flow<ProgressEvent> =
        c().reprocessHorizons(sessionId, editedFrames)

    /** Per-frame horizon overlay (kind + per-column Y) for grid drawing; null if unavailable. */
    suspend fun getOverlay(sessionId: String, frameIndex: Int, width: Int, height: Int): GetHorizonOverlayResponse? =
        try {
            c().getHorizonOverlay(sessionId, frameIndex, width, height)
        } catch (e: StarRpcException) {
            null
        }
}
