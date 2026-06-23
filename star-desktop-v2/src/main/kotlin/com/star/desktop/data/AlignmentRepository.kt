package com.star.desktop.data

import com.star.desktop.engine.StarClient
import com.star.desktop.engine.StarRpcException
import com.star.proto.AlignmentInfo
import com.star.proto.AlignmentSequence

/** Read-only alignment diagnostics for the Alignment window. */
class AlignmentRepository(private val clientProvider: () -> StarClient?) {

    private fun c(): StarClient = clientProvider() ?: throw StarRpcException(-1, "engine not connected")

    /** Whole-sequence alignment info (one round-trip). Null if not available yet. */
    suspend fun sequence(sessionId: String, includeHomography: Boolean = false, includePreviews: Boolean = false): AlignmentSequence? =
        try {
            c().getAlignmentSequence(sessionId, includeHomography, includePreviews)
        } catch (e: StarRpcException) {
            null
        }

    /** Single-frame detail (homography + aligned previews). Null if not available. */
    suspend fun frame(sessionId: String, frameIndex: Int): AlignmentInfo? =
        try {
            c().getAlignment(sessionId, frameIndex)
        } catch (e: StarRpcException) {
            null
        }
}
