package com.star.desktop.data

import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.toComposeImageBitmap
import com.star.desktop.util.Log
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import java.util.Collections
import java.util.LinkedHashMap
import javax.imageio.ImageIO

/**
 * Loads 8-bit display images (JPEG/PNG previews produced by `stard`) into Compose [ImageBitmap]s,
 * with an LRU cache bounded to [maxEntries]. The client only ever loads paths `stard` hands back via
 * `ImageRef` — it never computes a StarCore path itself.
 */
class ImageCache(private val maxEntries: Int = 120) {

    private val cache: MutableMap<String, ImageBitmap> = Collections.synchronizedMap(
        object : LinkedHashMap<String, ImageBitmap>(maxEntries, 0.75f, true) {
            override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, ImageBitmap>?) = size > maxEntries
        },
    )

    /** Which cached paths show which frame, so a frame's pictures can be dropped without knowing their paths. */
    private val pathsByFrame = java.util.concurrent.ConcurrentHashMap<Int, MutableSet<String>>()

    fun peek(path: String): ImageBitmap? = cache[path]

    /** Load [path], remembering (when [frameIndex] is given) that it is a picture of that frame. */
    suspend fun load(path: String, frameIndex: Int? = null): ImageBitmap? = withContext(Dispatchers.IO) {
        if (frameIndex != null) {
            pathsByFrame.computeIfAbsent(frameIndex) { java.util.concurrent.ConcurrentHashMap.newKeySet() }.add(path)
        }
        cache[path] ?: loadFromDisk(path)?.also { cache[path] = it }
    }

    /**
     * Read the image at [path] without keeping it: for the one full-size bitmap the view holds while zoomed in, which is far too
     * large to sit among the cache's previews.
     */
    suspend fun loadUncached(path: String): ImageBitmap? = withContext(Dispatchers.IO) { loadFromDisk(path) }

    /** `stard` rewrites a frame's images in place, so a path's old bitmap is wrong once the frame is saved. */
    fun invalidate(path: String) { cache.remove(path) }

    /** Drop every picture of frame [frameIndex] that was loaded with it. */
    fun invalidateFrame(frameIndex: Int) {
        pathsByFrame.remove(frameIndex)?.forEach { cache.remove(it) }
    }

    fun clear() {
        cache.clear()
        pathsByFrame.clear()
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
}
