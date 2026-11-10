package com.star.desktop.data

import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.toComposeImageBitmap
import com.star.desktop.util.Log
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import java.util.LinkedHashMap
import javax.imageio.ImageIO

/**
 * Loads 8-bit display images (JPEG/PNG previews produced by `stard`) into Compose [ImageBitmap]s,
 * with an LRU cache bounded to [maxBytes] of bitmap data (width x height x 4 bytes each), so a 1617 x 1080 preview weighs what
 * it costs and 80 x 60 thumbnails cannot push it out. One image larger than the budget is still kept, alone. The client only
 * ever loads paths `stard` hands back via `ImageRef` — it never computes a StarCore path itself.
 */
class ImageCache(private val maxBytes: Long = DEFAULT_MAX_BYTES) {

    /** Access-ordered, so the eldest entry is the least recently used. Every access holds the map's own lock. */
    private val cache = LinkedHashMap<String, ImageBitmap>(64, 0.75f, true)
    private var totalBytes = 0L

    /** Bytes of bitmap data currently cached. */
    val cachedBytes: Long get() = synchronized(cache) { totalBytes }

    /** Which cached paths show which frame, so a frame's pictures can be dropped without knowing their paths. */
    private val pathsByFrame = java.util.concurrent.ConcurrentHashMap<Int, MutableSet<String>>()

    fun peek(path: String): ImageBitmap? = synchronized(cache) { cache[path] }

    /** Load [path], remembering (when [frameIndex] is given) that it is a picture of that frame. */
    suspend fun load(path: String, frameIndex: Int? = null): ImageBitmap? = withContext(Dispatchers.IO) {
        if (frameIndex != null) {
            pathsByFrame.computeIfAbsent(frameIndex) { java.util.concurrent.ConcurrentHashMap.newKeySet() }.add(path)
        }
        synchronized(cache) { cache[path] } ?: loadFromDisk(path)?.also { put(path, it) }
    }

    /**
     * Read the image at [path] without keeping it: for the one full-size bitmap the view holds while zoomed in, which is far too
     * large to sit among the cache's previews.
     */
    suspend fun loadUncached(path: String): ImageBitmap? = withContext(Dispatchers.IO) { loadFromDisk(path) }

    /** `stard` rewrites a frame's images in place, so a path's old bitmap is wrong once the frame is saved. */
    fun invalidate(path: String) = synchronized(cache) { remove(path) }

    /** Drop every picture of frame [frameIndex] that was loaded with it. */
    fun invalidateFrame(frameIndex: Int) {
        pathsByFrame.remove(frameIndex)?.let { paths -> synchronized(cache) { paths.forEach { remove(it) } } }
    }

    fun clear() {
        synchronized(cache) {
            cache.clear()
            totalBytes = 0
        }
        pathsByFrame.clear()
    }

    private fun bytesOf(bitmap: ImageBitmap) = bitmap.width.toLong() * bitmap.height * 4

    /** Caller holds the lock. */
    private fun remove(path: String) {
        cache.remove(path)?.let { totalBytes -= bytesOf(it) }
    }

    /** Insert [bitmap], then drop least-recently-used entries until the budget holds, never the one just inserted. */
    private fun put(path: String, bitmap: ImageBitmap) = synchronized(cache) {
        remove(path)
        cache[path] = bitmap
        totalBytes += bytesOf(bitmap)
        val oldestFirst = cache.entries.iterator()
        while (totalBytes > maxBytes && oldestFirst.hasNext()) {
            val eldest = oldestFirst.next()
            if (eldest.key == path) break
            totalBytes -= bytesOf(eldest.value)
            oldestFirst.remove()
        }
    }

    private fun loadFromDisk(path: String): ImageBitmap? {
        val file = File(path)
        if (!file.exists()) {
            Log.w("ImageCache") { "file not found: $path" }
            return null
        }
        return try {
            ImageIO.read(file)?.toComposeImageBitmap()
                ?: run { Log.w("ImageCache") { "unreadable image: $path" }; null }
        } catch (e: Exception) {
            Log.e("ImageCache", e) { "failed to read $path" }
            null
        }
    }

    companion object {
        /** About 36 full-size previews. */
        const val DEFAULT_MAX_BYTES = 256L * 1024 * 1024
    }
}
