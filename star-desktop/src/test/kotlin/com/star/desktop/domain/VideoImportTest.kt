package com.star.desktop.domain

import com.star.proto.FrameFormat
import com.star.proto.ProbeVideoResponse
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

class VideoImportTest {
    private fun probe(frames: Int = 100) = ProbeVideoResponse.newBuilder()
        .setKnown(true).setWidth(4000).setHeight(3000).setFrameCount(frames)
        .setTiff16BytesPerPixel(6.0).setTiff8BytesPerPixel(3.0)
        .addAllJpegBytesPerPixel((1..100).map { it / 100.0 })
        .build()

    @Test fun `each format is priced from the per pixel table the daemon sent`() {
        val pixels = 4000L * 3000 * 100
        assertEquals(pixels * 6, VideoImport.estimatedBytes(probe(), FrameFormatChoice.TIFF16, 80))
        assertEquals(pixels * 3, VideoImport.estimatedBytes(probe(), FrameFormatChoice.TIFF8, 80))
        assertEquals(Math.round(pixels * 0.80), VideoImport.estimatedBytes(probe(), FrameFormatChoice.JPEG, 80))
        // out of range qualities are clamped into the table, not an index error
        assertEquals(Math.round(pixels * 1.00), VideoImport.estimatedBytes(probe(), FrameFormatChoice.JPEG, 500))
        assertEquals(Math.round(pixels * 0.01), VideoImport.estimatedBytes(probe(), FrameFormatChoice.JPEG, 0))
    }

    @Test fun `no estimate without a size and a length`() {
        assertNull(VideoImport.estimatedBytes(probe(frames = 0), FrameFormatChoice.TIFF16, 80))
        assertNull(VideoImport.estimatedBytes(ProbeVideoResponse.getDefaultInstance(), FrameFormatChoice.TIFF16, 80))
    }

    @Test fun `the choices map onto the protocol's formats and default to 16 bit tiff and jpeg 80`() {
        assertEquals(FrameFormat.FRAME_FORMAT_TIFF16, FrameFormatChoice.TIFF16.proto)
        assertEquals(FrameFormat.FRAME_FORMAT_TIFF8, FrameFormatChoice.TIFF8.proto)
        assertEquals(FrameFormat.FRAME_FORMAT_JPEG, FrameFormatChoice.JPEG.proto)
        assertEquals(80, VideoImport.DEFAULT_JPEG_QUALITY)
        assertEquals(FrameFormat.FRAME_FORMAT_TIFF16, FrameFormat.forNumber(0))
    }

    @Test fun `sizes are written in decimal units`() {
        assertEquals("512 bytes", VideoImport.formatBytes(512))
        assertEquals("1.5 KB", VideoImport.formatBytes(1500))
        assertTrue(VideoImport.formatBytes(2_300_000_000).startsWith("2.3 GB"))
    }
}
