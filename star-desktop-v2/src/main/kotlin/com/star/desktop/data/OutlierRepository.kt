package com.star.desktop.data

import com.star.desktop.engine.StarClient
import com.star.desktop.engine.StarRpcException
import com.star.desktop.util.Log
import com.star.proto.ImageRef
import com.star.proto.OutlierDecision
import com.star.proto.OutlierGroup
import com.star.proto.SetOutlierDecisionsResponse
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import javax.imageio.ImageIO

/**
 * Outlier group metadata + keep/remove decisions, plus the 16-bit label image used for client-side
 * hit-testing (pixel value = group id, 0 = none). Decisions persist through `stard` (StarCore writes
 * the same `OutlierGroupPaintData.json` the macOS app writes).
 */
class OutlierRepository(private val clientProvider: () -> StarClient?) {

    private fun c(): StarClient = clientProvider() ?: throw StarRpcException(-1, "engine not connected")

    suspend fun list(sessionId: String, frameIndex: Int): List<OutlierGroup> =
        try {
            c().listOutliers(sessionId, frameIndex).groupsList
        } catch (e: StarRpcException) {
            emptyList()
        }

    suspend fun setDecisions(
        sessionId: String,
        frameIndex: Int,
        decisions: List<OutlierDecision>,
        rerender: Boolean = false,
    ): SetOutlierDecisionsResponse = c().setOutlierDecisions(sessionId, frameIndex, decisions, rerender)

    suspend fun renderFrame(sessionId: String, frameIndex: Int): ImageRef = c().renderFrame(sessionId, frameIndex)

    /** Re-run the decision-tree classifier on one frame's outliers (`Outlier.ApplyDecisionTree`). */
    suspend fun applyDecisionTree(sessionId: String, frameIndex: Int, overwrite: Boolean) =
        c().applyDecisionTree(sessionId, frameIndex, overwrite = overwrite)

    /** Re-run the classifier over every frame (`Outlier.ApplyDecisionTreeAllFrames`). */
    suspend fun applyDecisionTreeAllFrames(sessionId: String, overwrite: Boolean) =
        c().applyDecisionTreeAllFrames(sessionId, overwrite = overwrite)

    /**
     * Load the 16-bit single-channel label PNG at [path] into a `group-id per pixel` array
     * (row-major, length w*h). Used for local click hit-testing without per-click round-trips.
     */
    suspend fun loadLabelMap(path: String): LabelMap? = withContext(Dispatchers.IO) {
        val file = File(path)
        if (!file.exists()) return@withContext null
        try {
            val img = ImageIO.read(file) ?: return@withContext null
            val w = img.width
            val h = img.height
            val out = IntArray(w * h)
            img.raster.getSamples(0, 0, w, h, 0, out) // band 0 = the 16-bit group id
            LabelMap(w, h, out)
        } catch (e: Exception) {
            Log.e("Outlier", e) { "failed to read label image $path" }
            null
        }
    }

    /** group id per pixel (0 = none), row-major. */
    data class LabelMap(val width: Int, val height: Int, val ids: IntArray) {
        fun idAt(x: Int, y: Int): Int =
            if (x in 0 until width && y in 0 until height) ids[y * width + x] else 0

        override fun equals(other: Any?) = this === other
        override fun hashCode() = System.identityHashCode(this)
    }
}
