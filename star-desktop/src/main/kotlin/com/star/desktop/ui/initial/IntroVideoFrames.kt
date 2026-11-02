package com.star.desktop.ui.initial

import java.io.File
import java.io.InputStream

/** Width the background video is decoded at; the height follows the clip's own shape (see [introVideoHeight]). */
const val INTRO_VIDEO_WIDTH = 1280

/**
 * The ffmpeg command line that decodes [video] to raw BGRA frames on stdout: looping forever, paced at the clip's own frame rate (`-re`),
 * scaled to [INTRO_VIDEO_WIDTH] by an explicit [height] so [RawFrameReader] and the filter always agree on the frame size.
 */
fun introVideoFfmpegArgs(ffmpeg: String, video: String, height: Int): List<String> = listOf(
    ffmpeg, "-hide_banner", "-loglevel", "error",
    "-stream_loop", "-1", "-re", "-i", video,
    "-vf", "scale=$INTRO_VIDEO_WIDTH:$height",
    "-f", "rawvideo", "-pix_fmt", "bgra", "-",
)

/** The `ffmpeg -i` probe: it prints the streams to stderr and exits with "at least one output file must be specified". */
fun introVideoProbeArgs(ffmpeg: String, video: String): List<String> = listOf(ffmpeg, "-hide_banner", "-i", video)

private val VIDEO_SIZE = Regex("""Video:[^\n]*?[\s,](\d{2,5})x(\d{2,5})(?=[\s,\[])""")

/** The first video stream's (width, height) from `ffmpeg -i` stderr, or null when there is none. */
fun parseVideoSize(stderr: String): Pair<Int, Int>? {
    val m = VIDEO_SIZE.find(stderr) ?: return null
    val w = m.groupValues[1].toInt()
    val h = m.groupValues[2].toInt()
    return if (w > 0 && h > 0) w to h else null
}

/** Height for a [INTRO_VIDEO_WIDTH]-wide copy of a [w] x [h] source, rounded down to even (never below 2). */
fun introVideoHeight(w: Int, h: Int): Int = maxOf(2, (INTRO_VIDEO_WIDTH.toLong() * h / w).toInt() and 1.inv())

/**
 * The ffmpeg to decode with: `ffmpeg[.exe]` in the packaged resources dir, then the developer trees `../external_binaries/bin` and
 * `external_binaries/bin`. Null when none exists, which means no background.
 */
fun resolveIntroFfmpeg(
    resourcesDir: String? = System.getProperty("compose.application.resources.dir"),
    devRoots: List<File> = listOf(File("../external_binaries/bin"), File("external_binaries/bin")),
    windows: Boolean = System.getProperty("os.name").orEmpty().lowercase().contains("win"),
): File? {
    val name = if (windows) "ffmpeg.exe" else "ffmpeg"
    val dirs = buildList {
        resourcesDir?.let { add(File(it)) }
        addAll(devRoots)
    }
    return dirs.map { File(it, name) }.firstOrNull { it.isFile }
}

/** Splits an ffmpeg `-f rawvideo -pix_fmt bgra` stream into whole [width] x [height] frames. */
class RawFrameReader(private val input: InputStream, width: Int, height: Int) {
    val frameBytes: Int = Math.multiplyExact(Math.multiplyExact(width, height), 4)

    /** The next whole frame, or null at end of stream (a partial tail is dropped). */
    fun next(): ByteArray? = ByteArray(frameBytes).takeIf { nextInto(it) }

    /** Fills [buf] (at least [frameBytes] long) with the next whole frame; false at end of stream, where a partial tail is dropped. */
    fun nextInto(buf: ByteArray): Boolean = input.readNBytes(buf, 0, frameBytes) == frameBytes
}
