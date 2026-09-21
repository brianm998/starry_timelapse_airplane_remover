package com.star.desktop.ui.initial

import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.awt.SwingPanel
import java.io.File
import javafx.application.Platform
import javafx.embed.swing.JFXPanel
import javafx.scene.Scene
import javafx.scene.layout.StackPane
import javafx.scene.media.Media
import javafx.scene.media.MediaPlayer
import javafx.scene.media.MediaView

private const val INTRO_VIDEO_NAME = "11_30_2024-fx3-aurora-topaz-star.mp4"

/**
 * Full-bleed looping background video on the initial screen (macOS `SplitRevealVideoView`).
 * Compose Desktop has no video playback of its own, so this embeds a JavaFX `MediaView` via
 * `SwingPanel`/`JFXPanel` — the standard way to mix JavaFX into a Compose Desktop app.
 *
 * Shows nothing (falls back to whatever background the caller draws behind it) if the asset
 * isn't staged — same as macOS's `Bundle.main.url` returning nil for a dev build that hasn't
 * fetched gui/videos.
 */
@Composable
fun IntroVideoBackground(modifier: Modifier = Modifier) {
    val file = remember { resolveIntroVideoFile() } ?: return
    SwingPanel(
        modifier = modifier.fillMaxSize(),
        factory = {
            val panel = JFXPanel()
            Platform.runLater {
                val mediaPlayer = MediaPlayer(Media(file.toURI().toString()))
                mediaPlayer.cycleCount = MediaPlayer.INDEFINITE
                val view = MediaView(mediaPlayer)
                view.isPreserveRatio = false
                val root = StackPane(view)
                view.fitWidthProperty().bind(root.widthProperty())
                view.fitHeightProperty().bind(root.heightProperty())
                panel.scene = Scene(root)
                mediaPlayer.play()
            }
            panel
        },
    )
}

/** Bundled resource dir (packaged app) or dev fallback (../gui/videos) — same file both clients share. */
private fun resolveIntroVideoFile(): File? {
    val bundled = System.getProperty("compose.application.resources.dir")
        ?.let { File(it, "videos/$INTRO_VIDEO_NAME") }
        ?.takeIf { it.exists() }
    if (bundled != null) return bundled
    return File("../gui/videos/$INTRO_VIDEO_NAME").takeIf { it.exists() }
}
