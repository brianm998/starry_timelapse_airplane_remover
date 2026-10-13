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

    /**
     * A daemon that traps on startup — the Windows engine that could not find its resources — must
     * be reported with Swift's own "Fatal error" line, and that line must reach the engine log.
     * Before this the user saw "engine stopped" and nothing else, because the stderr tail filter
     * only looked for "ERROR"/"crashed" and stderr itself went to System.err.
     */
    @Test
    fun startupTrapIsExplainedAndLogged() {
        if (isWindows) {
            println("[skip] startupTrapIsExplainedAndLogged — needs a POSIX shell to fake the daemon")
            return
        }
        val dir = Files.createTempDirectory("star-trap").toFile()
        val fake = File(dir, "stard")
        fake.writeText(
            "#!/bin/sh\n" +
                "echo 'StarCore/resource_bundle_accessor.swift:12: Fatal error: could not load resource bundle' >&2\n" +
                "exit 132\n",
        )
        assertTrue(fake.setExecutable(true), "could not mark fake stard executable")

        val proc = DaemonProcess(fake.absolutePath, File(dir, "scratch").absolutePath, onStderrLine = {})
        kotlinx.coroutines.runBlocking {
            proc.start(this)
            kotlinx.coroutines.withTimeout(10_000) {
                while (proc.deathDescription() == null || !proc.logFile.readText().contains("# stard exited")) {
                    kotlinx.coroutines.delay(20)
                }
            }
        }
        val death = proc.deathDescription()!!
        assertTrue("SIGILL" in death, "exit 132 not named: $death")
        assertTrue("could not load resource bundle" in death, "Fatal error line not surfaced: $death")
        assertTrue(proc.logFile.absolutePath in death, "engine log not pointed at: $death")
        assertTrue("Fatal error" in proc.logFile.readText(), "stderr not written to the engine log")
        dir.deleteRecursively()
    }
}
