package com.star.desktop.ui.initial

import java.io.ByteArrayInputStream
import java.io.File
import java.io.InputStream
import java.nio.file.Files
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull

/** The display-free parts of the start screen's ffmpeg-driven background video. */
class IntroVideoFramesTest {
    /** Hands out at most 1 to 3 bytes per read, like a pipe that delivers a frame in pieces. */
    private class TrickleStream(private val data: ByteArray) : InputStream() {
        private var pos = 0
        private var call = 0
        override fun read(): Int = if (pos < data.size) data[pos++].toInt() and 0xff else -1
        override fun read(b: ByteArray, off: Int, len: Int): Int {
            if (len == 0) return 0
            if (pos >= data.size) return -1
            val n = minOf(len, data.size - pos, 1 + call++ % 3)
            System.arraycopy(data, pos, b, off, n)
            pos += n
            return n
        }
    }

    @Test fun readsWholeFramesAcrossShortReads() {
        val w = 3
        val h = 2
        val size = w * h * 4
        val a = ByteArray(size) { it.toByte() }
        val b = ByteArray(size) { (100 + it).toByte() }
        val reader = RawFrameReader(TrickleStream(a + b), w, h)
        assertEquals(size, reader.frameBytes)
        assertContentEquals(a, reader.next())
        assertContentEquals(b, reader.next())
        assertNull(reader.next())
    }

    @Test fun stopsAtEndWithoutPartialFrame() {
        val size = 2 * 2 * 4
        val whole = ByteArray(size) { 7 }
        val reader = RawFrameReader(ByteArrayInputStream(whole + ByteArray(size - 1) { 9 }), 2, 2)
        assertContentEquals(whole, reader.next())
        assertNull(reader.next())
        assertNull(reader.next())
        assertNull(RawFrameReader(ByteArrayInputStream(ByteArray(0)), 2, 2).next())
    }

    @Test fun ffmpegArgsLoopScaleAndBgra() {
        val args = introVideoFfmpegArgs("/bin/ffmpeg", "/v/a.mp4", 720)
        assertEquals("/bin/ffmpeg", args.first())
        assertEquals("-1", args[args.indexOf("-stream_loop") + 1])
        assert("-re" in args)
        assertEquals("/v/a.mp4", args[args.indexOf("-i") + 1])
        assertEquals("scale=1280:720", args[args.indexOf("-vf") + 1])
        assertEquals("rawvideo", args[args.indexOf("-f") + 1])
        assertEquals("bgra", args[args.indexOf("-pix_fmt") + 1])
        assertEquals("-", args.last())
        // -stream_loop and -re are input options: they come before -i
        assert(args.indexOf("-stream_loop") < args.indexOf("-i") && args.indexOf("-re") < args.indexOf("-i"))
    }

    @Test fun parsesVideoSizeFromFfmpegStderr() {
        val stderr = """
            Input #0, mov,mp4,m4a,3gp,3g2,mj2, from 'x.mp4':
              Duration: 00:00:20.00, start: 0.000000, bitrate: 9000 kb/s
              Stream #0:0[0x1](und): Video: h264 (High) (avc1 / 0x31637661), yuv420p(tv, bt709, progressive), 3840x2160 [SAR 1:1 DAR 16:9], 9000 kb/s, 25 fps, 25 tbr
              Stream #0:1[0x2](und): Audio: aac (LC), 48000 Hz, stereo, fltp
            At least one output file must be specified
        """.trimIndent()
        assertEquals(3840 to 2160, parseVideoSize(stderr))
        assertNull(parseVideoSize("x.mp4: No such file or directory"))
        assertNull(parseVideoSize(""))

        assertEquals(720, introVideoHeight(3840, 2160))
        assertEquals(534, introVideoHeight(1920, 800))   // 533.33 -> 533 -> down to even
        assertEquals(1280, introVideoHeight(1280, 1280))
        assertEquals(0, introVideoHeight(1000, 999) % 2)
    }

    @Test fun noFfmpegOrNoVideoMeansNoBackground() {
        val empty = Files.createTempDirectory("introffmpeg-empty").toFile()
        val res = Files.createTempDirectory("introffmpeg-res").toFile()
        val dev = Files.createTempDirectory("introffmpeg-dev").toFile()
        try {
            assertNull(resolveIntroFfmpeg(null, listOf(empty), windows = false))
            assertNull(resolveIntroFfmpeg(empty.path, listOf(File(empty, "nope")), windows = false))

            File(dev, "ffmpeg").writeText("")
            assertEquals(File(dev, "ffmpeg"), resolveIntroFfmpeg(res.path, listOf(dev), windows = false))
            File(res, "ffmpeg").writeText("")
            assertEquals(File(res, "ffmpeg"), resolveIntroFfmpeg(res.path, listOf(dev), windows = false))

            // Windows looks for ffmpeg.exe only
            assertNull(resolveIntroFfmpeg(res.path, listOf(dev), windows = true))
            File(res, "ffmpeg.exe").writeText("")
            assertNotNull(resolveIntroFfmpeg(res.path, listOf(dev), windows = true))
        } finally {
            listOf(empty, res, dev).forEach { it.deleteRecursively() }
        }
    }
}
