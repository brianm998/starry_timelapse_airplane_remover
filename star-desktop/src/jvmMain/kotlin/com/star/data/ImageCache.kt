package com.star.data

import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.toComposeImageBitmap
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.awt.image.BufferedImage
import java.io.File
import java.util.Collections
import java.util.LinkedHashMap
import javax.imageio.ImageIO

/**
 * Loads PNG preview images (8-bit, produced by stard) into Compose ImageBitmaps.
 * Maintains an LRU cache bounded to [maxEntries] to limit heap usage.
 *
 * The client reads ONLY the paths that stard returns via ImageRef — never computing paths itself.
 */
class ImageCache(private val maxEntries: Int = 120) {

    private val cache: MutableMap<String, ImageBitmap> = Collections.synchronizedMap(
        object : LinkedHashMap<String, ImageBitmap>(maxEntries, 0.75f, true) {
            override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, ImageBitmap>?) =
                size > maxEntries
        },
    )

    /** Load a PNG preview (8-bit) from [path], using the cache. */
    suspend fun load(path: String): ImageBitmap? = withContext(Dispatchers.IO) {
        cache[path] ?: run {
            val bmp = loadFromDisk(path) ?: return@withContext null
            cache[path] = bmp
            bmp
        }
    }

    /** Invalidate a single cached path (e.g. after rerender). */
    fun invalidate(path: String) {
        cache.remove(path)
    }

    /** Drop all cached images. */
    fun clear() = cache.clear()

    private fun loadFromDisk(path: String): ImageBitmap? {
        val file = File(path)
        if (!file.exists()) {
            println("[ImageCache] file not found: $path")
            return null
        }
        val img: BufferedImage? = ImageIO.read(file)
        if (img == null) {
            println("[ImageCache] ImageIO.read returned null for: $path (size=${file.length()})")
            return null
        }
        println("[ImageCache] loaded ${img.width}x${img.height} type=${img.type} from: $path")
        return img.toComposeImageBitmap()
    }
}
