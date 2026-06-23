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

    fun peek(path: String): ImageBitmap? = cache[path]

    suspend fun load(path: String): ImageBitmap? = withContext(Dispatchers.IO) {
        cache[path] ?: loadFromDisk(path)?.also { cache[path] = it }
    }

    fun invalidate(path: String) { cache.remove(path) }
    fun clear() = cache.clear()

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
