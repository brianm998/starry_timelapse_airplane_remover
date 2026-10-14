package com.star.desktop.data

import kotlinx.coroutines.runBlocking
import java.awt.image.BufferedImage
import java.io.File
import javax.imageio.ImageIO
import kotlin.test.Test
import kotlin.test.assertNotNull
import kotlin.test.assertNotSame
import kotlin.test.assertNull
import kotlin.test.assertSame

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
}
