package com.star.desktop.data

import com.star.desktop.engine.StarClient
import com.star.desktop.engine.StarRpcException
import com.star.proto.ComputeHorizonInBandRequest
import com.star.proto.GetHorizonOverlayResponse
import com.star.proto.GetReferenceHorizonResponse
import com.star.proto.HorizonBandMethod
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

    /**
     * Run a StarCore horizon detector over the user-painted band (the live painter). All per-column
     * arrays are in the given space (image space here), length == [spaceWidth]; `-1` = unset. Returns
     * the per-column horizon Y (`-1` = no result), or null on RPC error.
     */
    suspend fun computeInBand(
        sessionId: String,
        frameIndex: Int,
        method: HorizonBandMethod,
        spaceWidth: Int,
        spaceHeight: Int,
        topBoundaryY: List<Int>,
        bottomBoundaryY: List<Int>,
        knownSkyFloorY: List<Int> = emptyList(),
        knownGroundCeilingY: List<Int> = emptyList(),
        beta: Double = 0.0,
    ): List<Int>? = try {
        val req = ComputeHorizonInBandRequest.newBuilder()
            .setSessionId(sessionId)
            .setFrameIndex(frameIndex)
            .setMethod(method)
            .setSpaceWidth(spaceWidth)
            .setSpaceHeight(spaceHeight)
            .addAllTopBoundaryY(topBoundaryY)
            .addAllBottomBoundaryY(bottomBoundaryY)
            .addAllKnownSkyFloorY(knownSkyFloorY)
            .addAllKnownGroundCeilingY(knownGroundCeilingY)
            .setBeta(beta)
            .build()
        c().computeHorizonInBand(req).columns.horizonYList
    } catch (e: StarRpcException) {
        null
    }

    /**
     * Best existing horizon (user reference > merged > raw) as per-column Y in the given space, for
     * seeding the painter when re-opening a frame that already has a (possibly auto-computed) horizon.
     * Returns null if none exists.
     */
    suspend fun bestExisting(sessionId: String, frameIndex: Int, spaceWidth: Int, spaceHeight: Int): List<Int>? =
        try {
            val r = c().getBestHorizon(sessionId, frameIndex, spaceWidth, spaceHeight)
            if (r.exists) r.columns.horizonYList else null
        } catch (e: StarRpcException) {
            null
        }
}
