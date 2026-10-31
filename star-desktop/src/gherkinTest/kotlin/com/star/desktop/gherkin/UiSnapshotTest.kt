package com.star.desktop.gherkin

import androidx.compose.ui.graphics.toAwtImage
import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.runDesktopComposeUiTest
import com.star.desktop.ui.app.AppScreen
import com.star.desktop.ui.app.AppViewModel
import com.star.desktop.ui.app.StarApp
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import java.awt.Color
import java.awt.image.BufferedImage
import java.io.File
import java.nio.file.Files
import javax.imageio.ImageIO
import org.junit.jupiter.api.Assumptions.assumeTrue
import kotlin.random.Random
import kotlin.test.Test
import kotlin.test.assertTrue

/**
 * Renders the desktop client's screens to PNG files, to be looked at (by a person, or by an assistant that can read an image): the real Compose root
 * ([StarApp]) offscreen over a real `stard`, a small synthetic sequence, and the view model's own dev hooks (`autoMode`) to land on each screen without
 * answering the startup prompts. Off unless `STAR_UI_SNAPSHOT_DIR` names a folder to write into:
 *
 *     STAR_UI_SNAPSHOT_DIR=/tmp/shots ./gradlew gherkinTest -Pstar.stard.path=$PWD/../daemon/.build/debug/stard --tests '*UiSnapshotTest*'
 *
 * `STAR_UI_SNAPSHOT_MODES` (comma separated) picks the screens: edit, grid, settings, progress, prerender, startup, removal, and those reached by
 * one more step: customlimits and rendervideo (a call on the view model), settingsgpu, settingsalignment, settingshorizon and settingsmemory (the
 * settings sheet's other tabs, which `settings` leaves on the first, by a click on the tab). The start screen is not
 * among them: it embeds a JavaFX video background, and JavaFX cannot start headless. The window is 1400 x 1100, as the Gherkin runner's.
 */
@OptIn(ExperimentalTestApi::class)
class UiSnapshotTest {

    /** The snapshot modes that are the settings sheet on a tab other than its first, and the tab (`settings.tab.<id>` in `gherkin/ui/ids.json`). */
    private companion object {
        val SETTINGS_TAB_MODES = mapOf(
            "settingsgpu" to "gpu", "settingsalignment" to "alignment", "settingshorizon" to "horizon", "settingsmemory" to "memory",
        )
    }

    /** Frames with a gradient sky, a horizon and some stars: enough for the client to open them and draw thumbnails. */
    private fun makeSequence(dir: File, frames: Int = 6) {
        dir.mkdirs()
        val width = 960
        val height = 640
        val rnd = Random(7)
        val stars = List(160) { Triple(rnd.nextInt(width), rnd.nextInt(height * 3 / 4), 120 + rnd.nextInt(130)) }
        for (n in 1..frames) {
            val img = BufferedImage(width, height, BufferedImage.TYPE_INT_RGB)
            for (y in 0 until height) for (x in 0 until width) {
                val sky = y < height * 3 / 4
                val v = if (sky) 12 + y * 40 / height else 6
                img.setRGB(x, y, Color(v, v, v + if (sky) 18 else 0).rgb)
            }
            for ((x, y, b) in stars) img.setRGB((x + n * 2) % width, y, Color(b, b, b).rgb)
            ImageIO.write(img, "jpg", File(dir, "frame_%03d.jpg".format(n)))
        }
    }

    @Test fun snapshots() {
        val out = System.getenv("STAR_UI_SNAPSHOT_DIR")?.takeIf { it.isNotEmpty() }
        assumeTrue(out != null, "STAR_UI_SNAPSHOT_DIR is not set")
        val outDir = File(out!!).apply { mkdirs() }
        val modes = System.getenv("STAR_UI_SNAPSHOT_MODES")?.split(',')?.map { it.trim() }?.filter { it.isNotEmpty() }
            ?: listOf("edit", "grid", "settings", "progress", "prerender")

        val scratch = Files.createTempDirectory("star-snapshots-").toFile()
        val realHome = System.getProperty("user.home")
        // The client keeps its preferences in ~/.star.userprefs.json: a test must neither read nor write the real one.
        System.setProperty("user.home", File(scratch, "home").apply { mkdirs() }.absolutePath)
        try {
            for (mode in modes) {
                val sequence = File(scratch, "seq-$mode")
                makeSequence(sequence)
                val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
                // A few screens are reached from a dev-hook mode by one more call, below.
                val settingsTab = SETTINGS_TAB_MODES[mode]
                val hook = when {
                    mode == "customlimits" || mode == "rendervideo" -> "edit"
                    settingsTab != null -> "settings"
                    else -> mode
                }
                val model = AppViewModel(scope, autoOpenPath = sequence.absolutePath, autoMode = hook, autoFrame = 2, releaseCheck = { null })
                try {
                    runDesktopComposeUiTest(width = 1400, height = 1100) {
                        // Nothing is composed until the sequence has opened: the start screen embeds a JavaFX video background.
                        val deadline = System.nanoTime() + 180_000_000_000L
                        while (model.screen.value !is AppScreen.Sequence) {
                            model.error.value?.let { error("opening the sequence failed: $it") }
                            check(System.nanoTime() < deadline) { "timed out waiting for the sequence to open (screen: ${model.screen.value})" }
                            Thread.sleep(50)
                        }
                        setContent { StarApp(model) }
                        when (mode) {
                            "customlimits" -> model.openCustomLimits()
                            "rendervideo" -> model.openRenderVideo()
                        }
                        if (settingsTab != null) {
                            // The tabs are there once the daemon has sent the config the sheet shows.
                            val tag = "settings.tab.$settingsTab"
                            val tabDeadline = System.nanoTime() + 60_000_000_000L
                            while (onAllNodesWithTag(tag, useUnmergedTree = true).fetchSemanticsNodes().isEmpty()) {
                                check(System.nanoTime() < tabDeadline) { "timed out waiting for the $settingsTab tab" }
                                waitForIdle(); Thread.sleep(100)
                            }
                            onNodeWithTag(tag, useUnmergedTree = true).performClick()
                        }
                        // Frames, thumbnails and the daemon's answers arrive on real threads, not on the test clock.
                        repeat(40) { waitForIdle(); Thread.sleep(150) }
                        val image = onRoot().captureToImage().toAwtImage()
                        val file = File(outDir, "$mode.png")
                        ImageIO.write(image, "png", file)
                        println("SNAPSHOT $mode -> $file (${image.width}x${image.height})")
                        assertTrue(file.length() > 1000, "the snapshot of $mode is empty")
                    }
                } finally {
                    scope.cancel()
                }
            }
        } finally {
            System.setProperty("user.home", realHome)
            scratch.deleteRecursively()
        }
    }
}
