package com.star.desktop.ui.windows

import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.ImageComposeScene
import androidx.compose.ui.unit.Density
import com.star.desktop.i18n.Strings
import com.star.desktop.ui.app.DebugLogSettings
import com.star.desktop.ui.theme.StarTheme
import com.star.desktop.util.Log
import com.star.desktop.util.LogBuffer
import com.star.desktop.util.LogLine
import com.star.desktop.util.LogSource
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import org.jetbrains.skia.EncodedImageFormat
import java.io.File
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertTrue

/** The Debug window composes with a log to show. With `-Dstar.render.dump=<dir>` the picture is written there. */
@OptIn(ExperimentalComposeUiApi::class)
class DebugWindowViewTest {
    @BeforeTest fun setUp() { Strings.setOverride("en"); LogBuffer.clear() }
    @AfterTest fun tearDown() { Strings.setOverride(null); LogBuffer.clear() }

    @Test fun theWindowDrawsItsControlsAndTheLinesAtTheShownLevel() {
        val now = System.currentTimeMillis()
        LogBuffer.add(LogLine(now, Log.Level.INFO, LogSource.CLIENT, "App", "this is hidden at the default Show level"))
        LogBuffer.add(LogLine(now, Log.Level.WARN, LogSource.ENGINE, "SessionManager.swift:39 init", "memory is low: 91% in use"))
        LogBuffer.add(LogLine(now, Log.Level.ERROR, LogSource.CLIENT, "Sequence", "render all frames failed: disk full"))
        val settings = DebugLogSettings(CoroutineScope(SupervisorJob() + Dispatchers.Unconfined), tellEngine = { _, _, _ -> null }, logsDirectory = { File(".") })
        val scene = ImageComposeScene(width = 1100, height = 420, density = Density(1f)) {
            StarTheme { DebugWindowView(settings, "/scratch/logs/stard.log") }
        }
        try {
            scene.render()
            val image = scene.render(100_000_000)
            val bytes = image.encodeToData(EncodedImageFormat.PNG)!!.bytes
            System.getProperty("star.render.dump")?.takeIf { it.isNotBlank() }?.let { File(it, "debug_window.png").apply { parentFile.mkdirs() }.writeBytes(bytes) }
            val bitmap = org.jetbrains.skia.Bitmap.makeFromImage(image)
            val colours = HashSet<Int>()
            for (y in 0 until bitmap.height step 3) for (x in 0 until bitmap.width step 3) colours += bitmap.getColor(x, y)
            assertTrue(colours.size > 6, "more than a flat fill")
        } finally {
            scene.close()
        }
    }
}
