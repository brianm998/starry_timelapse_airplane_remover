package com.star.desktop.domain

import com.star.proto.FrameFormat
import com.star.proto.ProbeVideoResponse
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
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

    @Test fun `uncompressed tiffs are priced from the exact bytes and packbits from the old numbers`() {
        val p = ProbeVideoResponse.newBuilder()
            .setKnown(true).setWidth(1000).setHeight(1000).setFrameCount(10)
            .setTiff16BytesPerPixel(6.1).setTiff8BytesPerPixel(3.1)
            .setTiff16RawBytesPerPixel(6.0).setTiff8RawBytesPerPixel(3.0).build()
        assertEquals(60_000_000L, VideoImport.estimatedBytes(p, FrameFormatChoice.TIFF16, 80, TiffCompressionChoice.NONE))
        assertEquals(61_000_000L, VideoImport.estimatedBytes(p, FrameFormatChoice.TIFF16, 80, TiffCompressionChoice.PACKBITS))
        assertEquals(30_000_000L, VideoImport.estimatedBytes(p, FrameFormatChoice.TIFF8, 80, TiffCompressionChoice.NONE))
        // an engine that sends no raw numbers (an older one) is priced as packbits rather than as nothing
        val old = ProbeVideoResponse.newBuilder().setKnown(true).setWidth(1000).setHeight(1000).setFrameCount(10).setTiff16BytesPerPixel(6.1).build()
        assertEquals(61_000_000L, VideoImport.estimatedBytes(old, FrameFormatChoice.TIFF16, 80, TiffCompressionChoice.NONE))
    }

    @Test fun `the compression defaults to what every earlier import wrote and maps onto the protocol`() {
        assertEquals(TiffCompressionChoice.PACKBITS, VideoImportOptions().tiffCompression)
        assertEquals(com.star.proto.TiffCompression.TIFF_COMPRESSION_PACKBITS, com.star.proto.TiffCompression.forNumber(0))
        assertEquals(com.star.proto.TiffCompression.TIFF_COMPRESSION_NONE, TiffCompressionChoice.NONE.proto)
        assertFalse(VideoImportOptions().extractInBackground)
    }

    @Test fun `extracting in the background starts on for a video any frame of which is cheap to reach`() {
        val seekable = ProbeVideoResponse.newBuilder().setKnown(true).setSeekable(true).setSeekableKnown(true).build()
        val longGop = ProbeVideoResponse.newBuilder().setKnown(true).setSeekable(false).setSeekableKnown(true).build()
        assertTrue(VideoImport.extractInBackgroundByDefault(seekable))
        assertFalse(VideoImport.extractInBackgroundByDefault(longGop))
        assertFalse(VideoImport.extractInBackgroundByDefault(null))
        assertFalse(VideoImport.extractInBackgroundByDefault(ProbeVideoResponse.getDefaultInstance()))
    }
}
