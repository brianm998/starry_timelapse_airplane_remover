package com.star.desktop.engine

import java.io.File
import java.nio.file.Files
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * `resolveStardBinary()` must find the daemon inside a packaged distribution — i.e. in the directory
 * named by Compose's `compose.application.resources.dir` property, where `stageAppResources` bundles
 * stard alongside ffmpeg/ffprobe. This is the production resolution path, so guard it.
 */
class DaemonProcessTest {

    private val isWindows = System.getProperty("os.name").orEmpty().lowercase().contains("win")
    private val exeName = if (isWindows) "stard.exe" else "stard"

    private var savedStardPath: String? = null
    private var savedResourcesDir: String? = null

    @BeforeTest fun saveProps() {
        savedStardPath = System.getProperty("star.stard.path")
        savedResourcesDir = System.getProperty("compose.application.resources.dir")
        // The -Dstar.stard.path dev override short-circuits resolution; clear it so we test the bundle path.
        System.clearProperty("star.stard.path")
    }

    @AfterTest fun restoreProps() {
        savedStardPath?.let { System.setProperty("star.stard.path", it) } ?: System.clearProperty("star.stard.path")
        savedResourcesDir?.let { System.setProperty("compose.application.resources.dir", it) } ?: System.clearProperty("compose.application.resources.dir")
    }

    @Test
    fun resolvesBundledStardFromComposeResourcesDir() {
        // STARD_PATH (env) would also short-circuit; if it's set in this environment, skip rather than mis-assert.
        if (System.getenv("STARD_PATH") != null) {
            println("[skip] resolvesBundledStardFromComposeResourcesDir — STARD_PATH is set in the environment")
            return
        }
        val resDir = Files.createTempDirectory("star-app-resources").toFile()
        val bundled = File(resDir, exeName)
        bundled.writeText("#!/bin/sh\nexit 0\n")
        assertTrue(bundled.setExecutable(true), "could not mark fake stard executable")

        System.setProperty("compose.application.resources.dir", resDir.absolutePath)

        assertEquals(
            bundled.absolutePath,
            DaemonProcess.resolveStardBinary(),
            "resolveStardBinary should return the stard bundled in the Compose resources dir",
        )
        resDir.deleteRecursively()
    }
}
