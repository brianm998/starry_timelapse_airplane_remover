package com.star.desktop.ui.initial

import com.star.desktop.domain.AspectFill
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.toComposeImageBitmap
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import java.io.File
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import org.jetbrains.skia.ColorAlphaType
import org.jetbrains.skia.ColorType
import org.jetbrains.skia.Image
import org.jetbrains.skia.ImageInfo

/** How many decoded frames stay open (about a tenth of a second at 25 fps) before the oldest is closed. */
private const val FRAMES_KEPT_OPEN = 4

private const val INTRO_VIDEO_NAME = "11_30_2024-fx3-aurora-topaz-star.mp4"

/** Set (to anything) by a UI test host to have the start screen draw no video; see [IntroVideoBackground]. */
const val NO_INTRO_VIDEO_PROPERTY = "star.ui.noIntroVideo"

/**
 * Full-bleed looping background video on the initial screen (macOS `SplitRevealVideoView`).
 *
 * Compose Desktop has no video playback of its own, and a `SwingPanel` is always drawn over every Compose element, hiding the drop zone and
 * buttons. So the bundled ffmpeg decodes the clip to raw BGRA frames on a pipe ([introVideoFfmpegArgs]); each whole frame becomes an
 * `ImageBitmap` that `Canvas` draws aspect-filled like any other Compose content, and the rest of the start screen layers on top.
 *
 * Shows nothing (falls back to whatever background the caller draws behind it) if the asset or ffmpeg isn't there, or if anything fails -
 * same as macOS's `Bundle.main.url` returning nil for a dev build that hasn't fetched gui/videos. Leaving composition cancels the effect,
 * which kills the ffmpeg child.
 */
@Composable
fun IntroVideoBackground(modifier: Modifier = Modifier) {
    // A UI test host asks for no video: it should not spawn ffmpeg, and the start screen is then seen as it is without the background.
    if (System.getProperty(NO_INTRO_VIDEO_PROPERTY) != null) return
    val file = remember { resolveIntroVideoFile() } ?: return
    var frame by remember { mutableStateOf<ImageBitmap?>(null) }

    LaunchedEffect(file) {
        withContext(Dispatchers.IO) {
            runCatching { playIntroVideo(file) { frame = it } }
        }
    }

    Canvas(modifier.fillMaxSize()) {
        frame?.let { bmp ->
            val dst = IntSize(size.width.toInt(), size.height.toInt())
            val part = AspectFill.source(bmp.width, bmp.height, dst.width, dst.height)
            drawImage(image = bmp, srcOffset = IntOffset(part.x, part.y), srcSize = IntSize(part.width, part.height), dstSize = dst)
        }
    }
}

/** Runs ffmpeg on [file] and hands every decoded frame to [onFrame] until cancelled; the child is always killed on the way out. */
private fun kotlinx.coroutines.CoroutineScope.playIntroVideo(file: File, onFrame: (ImageBitmap) -> Unit) {
    val ffmpeg = resolveIntroFfmpeg() ?: return
    val (w, h) = parseVideoSize(probeIntroVideo(ffmpeg, file)) ?: return
    val height = introVideoHeight(w, h)
    val process = ProcessBuilder(introVideoFfmpegArgs(ffmpeg.path, file.path, height)).start()
    val recent = ArrayDeque<Image>()
    val hook = Thread { process.destroyForcibly() }
    Runtime.getRuntime().addShutdownHook(hook)
    try {
        process.outputStream.close()
        // ffmpeg's stderr must be read or a full pipe blocks it; with -loglevel error it only ever says what went wrong.
        Thread { runCatching { process.errorStream.copyTo(java.io.OutputStream.nullOutputStream()) } }.apply { isDaemon = true }.start()
        val reader = RawFrameReader(process.inputStream.buffered(1 shl 20), INTRO_VIDEO_WIDTH, height)
        val buf = ByteArray(reader.frameBytes)
        val info = ImageInfo(INTRO_VIDEO_WIDTH, height, ColorType.BGRA_8888, ColorAlphaType.OPAQUE)
        // Every frame is a native Skia picture of ~3.7 MB, ~90 MB/s at video rate. The JVM-side wrappers are tiny, so the garbage collector
        // would hardly ever run the cleaners that free them and native memory would climb for as long as the start screen is open. So each
        // picture is closed explicitly once it is a few frames old: long enough that the draw which took it has finished with it.
        while (reader.nextInto(buf)) {
            ensureActive()
            // makeRaster copies the pixels, so buf is free to be refilled while the picture just handed over is still being drawn.
            val image = Image.makeRaster(info, buf, INTRO_VIDEO_WIDTH * 4)
            recent.addLast(image)
            onFrame(image.toComposeImageBitmap())
            if (recent.size > FRAMES_KEPT_OPEN) recent.removeFirst().close()
        }
    } finally {
        // all but the newest, which the canvas may still be drawing; that one is left to the garbage collector
        while (recent.size > 1) recent.removeFirst().close()
        process.destroyForcibly()
        runCatching { Runtime.getRuntime().removeShutdownHook(hook) }
    }
}

/** `ffmpeg -i video` stderr, which names the stream sizes; "" if it cannot be run. */
private fun probeIntroVideo(ffmpeg: File, file: File): String = runCatching {
    val p = ProcessBuilder(introVideoProbeArgs(ffmpeg.path, file.path)).redirectErrorStream(true).start()
    p.outputStream.close()
    try {
        String(p.inputStream.readBytes())
    } finally {
        p.destroyForcibly()
    }
}.getOrDefault("")

/** Bundled resource dir (packaged app) or dev fallback (../gui/videos) — same file both clients share. */
private fun resolveIntroVideoFile(): File? {
    val bundled = System.getProperty("compose.application.resources.dir")
        ?.let { File(it, "videos/$INTRO_VIDEO_NAME") }
        ?.takeIf { it.exists() }
    if (bundled != null) return bundled
    return File("../gui/videos/$INTRO_VIDEO_NAME").takeIf { it.exists() }
}
