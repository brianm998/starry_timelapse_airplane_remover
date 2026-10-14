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

    /** Each of [groupIds]' decision-tree features and classifier score in a frame (all its groups when empty); a group's size in pixels is on the group. */
    suspend fun features(sessionId: String, frameIndex: Int, groupIds: List<Int> = emptyList()): List<com.star.proto.OutlierFeatureRow> =
        c().getOutlierFeatures(sessionId, frameIndex, groupIds).rowsList

    suspend fun setDecisions(
        sessionId: String,
        frameIndex: Int,
        decisions: List<OutlierDecision>,
        rerender: Boolean = false,
    ): SetOutlierDecisionsResponse = c().setOutlierDecisions(sessionId, frameIndex, decisions, rerender)

    /** Keep All / Remove All / Clear Undecided on one frame, the trash too when asked (`Outlier.SetAll`). */
    suspend fun setAll(sessionId: String, frameIndex: Int, shouldRemove: Boolean, undecidedOnly: Boolean, includingTrash: Boolean) =
        c().setAllOutliers(sessionId, frameIndex, shouldRemove, undecidedOnly, includingTrash)

    /**
     * Read an 8-bit mask PNG (255 = set) into a [TrashMask]: one boolean-ish byte per pixel, row-major. Used to draw the trash
     * without a view per trashed group.
     */
    suspend fun loadMask(path: String): Mask? = withContext(Dispatchers.IO) {
        val file = File(path)
        if (!file.exists()) return@withContext null
        try {
            val img = ImageIO.read(file) ?: return@withContext null
            val w = img.width
            val h = img.height
            val bytes = ByteArray(w * h)
            val row = IntArray(w)
            for (y in 0 until h) {
                img.raster.getSamples(0, y, w, 1, 0, row)
                val base = y * w
                for (x in 0 until w) bytes[base + x] = if (row[x] > 0) 1 else 0
            }
            Mask(w, h, bytes)
        } catch (e: Exception) {
            Log.e("Outlier", e) { "failed to read mask $path" }
            null
        }
    }

    /** A set/unset flag per pixel, row-major. */
    class Mask(val width: Int, val height: Int, val set: ByteArray)

    suspend fun renderFrame(sessionId: String, frameIndex: Int): ImageRef = c().renderFrame(sessionId, frameIndex)

    /** Run the decision-tree classifier on one frame's outliers (`Outlier.ApplyDecisionTree`). */
    suspend fun applyDecisionTree(
        sessionId: String, frameIndex: Int, overwrite: Boolean,
        autoOnly: Boolean = false, includingTrash: Boolean = false, minimumSize: Int = 0, rerender: Boolean = false,
    ) = c().applyDecisionTree(
        sessionId, frameIndex, overwrite,
        autoOnly = autoOnly, includingTrash = includingTrash, minimumSize = minimumSize, rerender = rerender,
    )

    /** Run the classifier over every frame (`Outlier.ApplyDecisionTreeAllFrames`). */
    suspend fun applyDecisionTreeAllFrames(sessionId: String, overwrite: Boolean, minimumSize: Int = 0) =
        c().applyDecisionTreeAllFrames(sessionId, overwrite = overwrite, minimumSize = minimumSize)

    /** Set keep/remove for outliers in a rectangular area across [startIndex,endIndex] (image px). */
    suspend fun setDecisionsInArea(
        sessionId: String, startIndex: Int, endIndex: Int, shouldRemove: Boolean,
        startX: Float, startY: Float, endX: Float, endY: Float, overlapping: Boolean = false, includingTrash: Boolean = false,
    ) = c().setOutlierDecisionsInArea(
        sessionId, startIndex, endIndex, shouldRemove,
        com.star.proto.Point.newBuilder().setX(startX.toDouble()).setY(startY.toDouble()).build(),
        com.star.proto.Point.newBuilder().setX(endX.toDouble()).setY(endY.toDouble()).build(),
        includingTrash = includingTrash, overlapping = overlapping,
    )

    /** Set keep/remove for outliers overlapping a reference group across [startIndex,endIndex]. */
    suspend fun setDecisionsOverlapping(
        sessionId: String, startIndex: Int, endIndex: Int, shouldRemove: Boolean,
        referenceFrame: Int, referenceGroupId: Int,
    ) = c().setOutlierDecisionsOverlapping(sessionId, startIndex, endIndex, shouldRemove, referenceFrame, referenceGroupId)

    /**
     * Apply a single-frame area editing tool (razor/shovel/trash/extract) to a drag rectangle (image px).
     * [groupId] > 0 is TRASH-only: dump exactly that group (single-tap), ignoring the rectangle.
     */
    suspend fun applyAreaTool(
        sessionId: String, frameIndex: Int, tool: com.star.proto.OutlierAreaTool,
        startX: Float, startY: Float, endX: Float, endY: Float, includingTrash: Boolean = false, groupId: Int = 0,
    ) = c().applyOutlierAreaTool(
        sessionId, frameIndex, tool,
        com.star.proto.Point.newBuilder().setX(startX.toDouble()).setY(startY.toDouble()).build(),
        com.star.proto.Point.newBuilder().setX(endX.toDouble()).setY(endY.toDouble()).build(),
        includingTrash = includingTrash, groupId = groupId,
    )

    /**
     * Load the 16-bit single-channel label PNG at [path] into a `group-id per pixel` array
     * (row-major, length w*h). Used for local click hit-testing without per-click round-trips.
     *
     * Read a row at a time into 16-bit storage: ids are 16-bit, and a 42 MP frame is 84 MB this way, where an
     * `IntArray` of the whole image was 170 MB, twice over while it was being filled.
     */
    suspend fun loadLabelMap(path: String): LabelMap? = withContext(Dispatchers.IO) {
        val file = File(path)
        if (!file.exists()) return@withContext null
        try {
            val img = ImageIO.read(file) ?: return@withContext null
            val w = img.width
            val h = img.height
            val ids = ShortArray(w * h)
            val row = IntArray(w)
            for (y in 0 until h) {
                img.raster.getSamples(0, y, w, 1, 0, row) // band 0 = the 16-bit group id
                val base = y * w
                for (x in 0 until w) ids[base + x] = row[x].toShort()
            }
            LabelMap(w, h, ids)
        } catch (e: Exception) {
            Log.e("Outlier", e) { "failed to read label image $path" }
            null
        }
    }

    /** group id per pixel (0 = none), row-major; ids are unsigned 16-bit, stored as the same bits in a short. */
    data class LabelMap(val width: Int, val height: Int, val ids: ShortArray) {
        fun idAt(x: Int, y: Int): Int =
            if (x in 0 until width && y in 0 until height) ids[y * width + x].toInt() and 0xFFFF else 0

        override fun equals(other: Any?) = this === other
        override fun hashCode() = System.identityHashCode(this)
    }
}
