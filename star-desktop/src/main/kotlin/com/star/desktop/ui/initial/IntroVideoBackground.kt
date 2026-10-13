package com.star.desktop.ui.initial

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.toComposeImageBitmap
import androidx.compose.ui.unit.IntSize
import java.io.File
import javafx.animation.AnimationTimer
import javafx.application.Platform
import javafx.embed.swing.JFXPanel
import javafx.embed.swing.SwingFXUtils
import javafx.scene.Scene
import javafx.scene.SnapshotParameters
import javafx.scene.image.WritableImage
import javafx.scene.layout.StackPane
import javafx.scene.media.Media
import javafx.scene.media.MediaPlayer
import javafx.scene.media.MediaView

private const val INTRO_VIDEO_NAME = "11_30_2024-fx3-aurora-topaz-star.mp4"

// Fixed off-screen render resolution for the snapshot loop; Canvas.drawImage below scales it to
// fill whatever size the initial screen actually is (the same stretch-to-fill the old
// fitWidth/fitHeight binding gave a live-embedded MediaView).
private const val SNAPSHOT_WIDTH = 1280.0
private const val SNAPSHOT_HEIGHT = 720.0

/**
 * Full-bleed looping background video on the initial screen (macOS `SplitRevealVideoView`).
 *
 * Compose Desktop has no video playback of its own. An earlier version of this embedded a JavaFX
 * `MediaView` directly via `SwingPanel`/`JFXPanel` — but Compose Desktop always draws `SwingPanel`
 * content on top of every other Compose composable in the window, regardless of where it sits in
 * the composition tree. That hid the drop zone and the Open/Load buttons the initial screen needs
 * to be usable. Instead, this decodes frames off-screen (a `MediaView` inside a `Scene` that is
 * never attached to any visible AWT container) and periodically snapshots them into a plain
 * Compose `ImageBitmap`, drawn via `Canvas` like any other Compose content — so the rest of the
 * initial screen layers normally on top of it.
 *
 * Shows nothing (falls back to whatever background the caller draws behind it) if the asset isn't
 * staged — same as macOS's `Bundle.main.url` returning nil for a dev build that hasn't fetched
 * gui/videos.
 */
@Composable
fun IntroVideoBackground(modifier: Modifier = Modifier) {
    val file = remember { resolveIntroVideoFile() } ?: return
    var frame by remember { mutableStateOf<ImageBitmap?>(null) }

    DisposableEffect(file) {
        // JFXPanel()'s constructor is the standard way to force JavaFX toolkit startup before any
        // Scene/MediaPlayer is touched. This instance is discarded — never added to any container.
        JFXPanel()
        var player: MediaPlayer? = null
        var timer: AnimationTimer? = null
        Platform.runLater {
            val p = MediaPlayer(Media(file.toURI().toString()))
            p.cycleCount = MediaPlayer.INDEFINITE
            val view = MediaView(p)
            view.isPreserveRatio = false
            view.fitWidth = SNAPSHOT_WIDTH
            view.fitHeight = SNAPSHOT_HEIGHT
            // Never shown in any Window — snapshot() below renders it on demand regardless — but a
            // MediaView needs a Scene attached for its decode/present pipeline to have somewhere to draw.
            Scene(StackPane(view), SNAPSHOT_WIDTH, SNAPSHOT_HEIGHT)
            player = p

            val params = SnapshotParameters()
            var writable: WritableImage? = null
            val t = object : AnimationTimer() {
                override fun handle(now: Long) {
                    writable = view.snapshot(params, writable)
                    val wi = writable ?: return
                    frame = SwingFXUtils.fromFXImage(wi, null).toComposeImageBitmap()
                }
            }
            timer = t
            t.start()
            p.play()
        }
        onDispose {
            Platform.runLater {
                timer?.stop()
                player?.stop()
                player?.dispose()
            }
        }
    }

    Canvas(modifier.fillMaxSize()) {
        frame?.let { bmp ->
            drawImage(image = bmp, dstSize = IntSize(size.width.toInt(), size.height.toInt()))
        }
    }
}

/** Bundled resource dir (packaged app) or dev fallback (../gui/videos) — same file both clients share. */
private fun resolveIntroVideoFile(): File? {
    val bundled = System.getProperty("compose.application.resources.dir")
        ?.let { File(it, "videos/$INTRO_VIDEO_NAME") }
        ?.takeIf { it.exists() }
    if (bundled != null) return bundled
    return File("../gui/videos/$INTRO_VIDEO_NAME").takeIf { it.exists() }
}
