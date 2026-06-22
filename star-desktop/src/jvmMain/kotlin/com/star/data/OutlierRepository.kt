package com.star.data

import com.star.engine.StarClient
import com.star.engine.StarRpcException
import com.star.proto.*
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.awt.image.BufferedImage
import java.awt.image.DataBufferUShort
import java.io.File
import javax.imageio.ImageIO

/**
 * 16-bit single-channel label image loaded into memory for local hit-testing.
 * Pixel value = group id (0 = no group).
 */
class LabelImage(
    val width: Int,
    val height: Int,
    private val pixels: ShortArray,   // row-major, index = y*width + x
) {
    /** Returns the group id at image-space coordinates, or 0 if out of bounds. */
    fun groupIdAt(x: Int, y: Int): Int {
        if (x < 0 || y < 0 || x >= width || y >= height) return 0
        return pixels[y * width + x].toInt() and 0xFFFF
    }
}

/** Manages outlier groups, label images, and set-decision calls for a single session. */
class OutlierRepository(private val client: StarClient) {

    suspend fun getGroups(sessionId: String, frameIndex: Int): List<OutlierGroup> =
        try {
            client.listOutliers(sessionId, frameIndex).groupsList
        } catch (_: StarRpcException) {
            // Daemon returns an error when outlier data isn't loaded yet (frame not yet processed).
            emptyList()
        }

    suspend fun getLabelImage(sessionId: String, frameIndex: Int): LabelImage? {
        val ref = try {
            client.getOutlierLabelImage(sessionId, frameIndex)
        } catch (_: Exception) {
            return null
        }

        return withContext(Dispatchers.IO) {
            loadLabelImage(ref.path)
        }
    }

    suspend fun setDecisions(
        sessionId: String,
        frameIndex: Int,
        decisions: List<OutlierDecision>,
        rerender: Boolean = false,
    ): SetOutlierDecisionsResponse = client.setOutlierDecisions(sessionId, frameIndex, decisions, rerender)

    suspend fun renderFrame(sessionId: String, frameIndex: Int): ImageRef =
        client.renderFrame(sessionId, frameIndex)

    companion object {
        /** Load a 16-bit grayscale PNG label image from disk. */
        fun loadLabelImage(path: String): LabelImage? {
            val file = File(path)
            if (!file.exists()) return null
            val img: BufferedImage = ImageIO.read(file) ?: return null

            val width = img.width
            val height = img.height
            val raster = img.raster
            val dataBuffer = raster.dataBuffer

            // 16-bit grayscale → DataBufferUShort
            if (dataBuffer is DataBufferUShort) {
                return LabelImage(width, height, dataBuffer.data)
            }

            // 8-bit fallback (should not happen for label images)
            val pixels = ShortArray(width * height)
            for (y in 0 until height) {
                for (x in 0 until width) {
                    pixels[y * width + x] = raster.getSample(x, y, 0).toShort()
                }
            }
            return LabelImage(width, height, pixels)
        }
    }
}
