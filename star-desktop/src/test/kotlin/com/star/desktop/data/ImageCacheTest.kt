package com.star.desktop.data

import kotlinx.coroutines.runBlocking
import java.awt.image.BufferedImage
import java.io.File
import javax.imageio.ImageIO
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNotSame
import kotlin.test.assertNull
import kotlin.test.assertSame
import kotlin.test.assertTrue

/** `stard` rewrites a frame's previews in place; the cache has to be able to forget them by frame. */
class ImageCacheTest {
    private fun png(name: String, shade: Int): File {
        val f = File.createTempFile(name, ".png")
        f.deleteOnExit()
        val img = BufferedImage(4, 4, BufferedImage.TYPE_INT_RGB)
        for (x in 0 until 4) for (y in 0 until 4) img.setRGB(x, y, shade * 0x010101)
        ImageIO.write(img, "png", f)
        return f
    }

    private fun sized(name: String, width: Int, height: Int): File {
        val f = File.createTempFile(name, ".png")
        f.deleteOnExit()
        ImageIO.write(BufferedImage(width, height, BufferedImage.TYPE_INT_RGB), "png", f)
        return f
    }

    @Test
    fun aCachedPictureIsServedWithoutReadingTheFileAgain() = runBlocking {
        val cache = ImageCache()
        val f = png("cached", 10)
        val first = cache.load(f.path, 3)
        f.delete()
        assertSame(first, cache.load(f.path, 3))
    }

    @Test
    fun invalidatingAFrameDropsEveryPictureLoadedForIt() = runBlocking {
        val cache = ImageCache()
        val a = png("first", 10)
        val b = png("second", 20)
        val other = png("other", 30)
        cache.load(a.path, 3)
        cache.load(b.path, 3)
        val kept = cache.load(other.path, 4)

        cache.invalidateFrame(3)

        assertNull(cache.peek(a.path), "frame 3's first picture survived invalidation")
        assertNull(cache.peek(b.path), "frame 3's second picture survived invalidation")
        assertSame(kept, cache.peek(other.path), "another frame's picture was dropped")
    }

    @Test
    fun aPictureRewrittenInPlaceIsReadAgainAfterInvalidation() = runBlocking {
        val cache = ImageCache()
        val f = png("rewritten", 10)
        val before = cache.load(f.path, 1)
        ImageIO.write(BufferedImage(8, 8, BufferedImage.TYPE_INT_RGB), "png", f)

        cache.invalidateFrame(1)
        val after = cache.load(f.path, 1)

        assertNotNull(after)
        assertNotSame(before, after)
    }

    @Test
    fun picturesLoadedWithoutAFrameAreOnlyDroppedByPath() = runBlocking {
        val cache = ImageCache()
        val f = png("nameless", 10)
        val bmp = cache.load(f.path)
        cache.invalidateFrame(0)
        assertSame(bmp, cache.peek(f.path))
        cache.invalidate(f.path)
        assertNull(cache.peek(f.path))
    }

    @Test
    fun largeImagesAreEvictedByBytes() = runBlocking {
        val each = 100L * 100 * 4
        val budget = 3 * each
        val cache = ImageCache(maxBytes = budget)
        val files = (0 until 6).map { sized("large$it", 100, 100) }
        for (f in files) {
            cache.load(f.path)
            assertTrue(cache.cachedBytes <= budget, "cache holds ${cache.cachedBytes} bytes, budget is $budget")
        }
        assertEquals(3 * each, cache.cachedBytes)
        assertNull(cache.peek(files[0].path), "the least recently used picture was kept")
        assertNotNull(cache.peek(files[5].path), "the newest picture was dropped")

        // a single image larger than the budget is still kept, alone
        val huge = sized("huge", 200, 200)
        cache.load(huge.path)
        assertNotNull(cache.peek(huge.path))
        assertEquals(200L * 200 * 4, cache.cachedBytes)
        assertNull(cache.peek(files[5].path))
    }

    @Test
    fun manySmallImagesDoNotEvictALargeOne() = runBlocking {
        val cache = ImageCache()
        val preview = sized("preview", 1617, 1080)
        val bmp = cache.load(preview.path)
        val thumb = sized("thumb", 80, 60)
        for (i in 0 until 200) {
            // distinct paths with the same pixels
            val copy = File.createTempFile("thumb$i", ".png").also { it.deleteOnExit() }
            thumb.copyTo(copy, overwrite = true)
            cache.load(copy.path)
        }
        assertSame(bmp, cache.peek(preview.path), "200 thumbnails evicted the preview")
    }

    @Test
    fun byteTotalFollowsInvalidation() = runBlocking {
        val cache = ImageCache()
        val a = sized("tiny-a", 10, 10)
        val b = sized("tiny-b", 20, 10)
        val c = sized("tiny-c", 30, 10)
        cache.load(a.path, 1)
        cache.load(b.path, 1)
        cache.load(c.path, 2)
        assertEquals((100 + 200 + 300) * 4L, cache.cachedBytes)

        cache.invalidate(c.path)
        assertEquals((100 + 200) * 4L, cache.cachedBytes)

        cache.invalidateFrame(1)
        assertEquals(0L, cache.cachedBytes)

        cache.load(a.path)
        cache.load(b.path)
        cache.clear()
        assertEquals(0L, cache.cachedBytes)

        // invalidating something not cached changes nothing
        cache.load(a.path)
        cache.invalidate(b.path)
        assertEquals(100 * 4L, cache.cachedBytes)
    }
}
