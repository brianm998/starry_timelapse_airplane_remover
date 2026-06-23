package com.star.desktop.engine

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import java.io.File
import java.io.InputStream
import java.io.OutputStream

/**
 * Spawns and supervises the `stard` child process (design §4).
 *
 * Owns its three streams: **stdin** (client→daemon frames), **stdout** (daemon→client frames),
 * **stderr** (human-readable daemon logs → drained to a sink; never parsed as protocol).
 *
 * Fixes vs the v1 client:
 *  - **No `--log-file`** — that flag does not exist on `stard` and makes it exit non-zero. The real
 *    CLI is `stard --scratch <dir> [-l|--log-level debug|info|warn|error]`. A log file is achieved by
 *    routing the drained stderr to a sink.
 */
class DaemonProcess(
    private val binaryPath: String,
    private val scratchDir: String,
    private val logLevel: String = "info",
    private val onStderrLine: (String) -> Unit = { System.err.println("[stard] $it") },
) {
    private var process: Process? = null
    private var stderrJob: Job? = null

    val stdin: OutputStream get() = process?.outputStream ?: error("daemon not started")
    val stdout: InputStream get() = process?.inputStream ?: error("daemon not started")

    fun start(logScope: CoroutineScope) {
        File(scratchDir).mkdirs()
        val proc = ProcessBuilder(binaryPath, "--scratch", scratchDir, "--log-level", logLevel)
            .redirectErrorStream(false) // keep stdout (frames) and stderr (logs) separate
            .start()
        process = proc
        // Insurance against an orphaned daemon if the JVM exits abnormally (stdin-EOF is the normal path).
        Runtime.getRuntime().addShutdownHook(Thread { if (proc.isAlive) proc.destroy() })
        stderrJob = logScope.launch(Dispatchers.IO) {
            proc.errorStream.bufferedReader().forEachLine(onStderrLine)
        }
    }

    fun isAlive(): Boolean = process?.isAlive == true

    fun exitValueOrNull(): Int? = try {
        process?.exitValue()
    } catch (_: IllegalThreadStateException) {
        null // still running
    }

    fun destroy() {
        stderrJob?.cancel()
        runCatching { process?.outputStream?.close() } // close stdin → daemon gets EOF (clean-exit backstop, design §2.1)
        process?.destroy()
        process = null
    }

    companion object {
        /**
         * Resolve the `stard` binary. Precedence:
         *  1. `-Dstar.stard.path=...` system property (dev override),
         *  2. `STARD_PATH` env var,
         *  3. next to the app executable (distribution bundle),
         *  4. developer build trees (daemon/.build/{debug,release}/stard relative to common roots).
         */
        fun resolveStardBinary(): String {
            System.getProperty("star.stard.path")?.let { if (File(it).canExecute()) return it }
            System.getenv("STARD_PATH")?.let { if (File(it).canExecute()) return it }

            val execDir = runCatching {
                File(DaemonProcess::class.java.protectionDomain.codeSource.location.toURI()).parentFile
            }.getOrNull()

            val exeName = if (isWindows()) "stard.exe" else "stard"
            val candidates = buildList {
                if (execDir != null) {
                    add(File(execDir, exeName))
                    add(File(execDir.parentFile ?: execDir, exeName))
                }
                // Developer trees — relative to the working dir or a parent containing `daemon/`.
                val roots = listOf(".", "..", "../..")
                for (r in roots) {
                    add(File(r, "daemon/.build/release/$exeName"))
                    add(File(r, "daemon/.build/debug/$exeName"))
                }
            }
            return candidates.firstOrNull { it.exists() && it.canExecute() }?.absolutePath
                ?: error(
                    "stard binary not found. Set -Dstar.stard.path=/path/to/stard, or build the daemon " +
                        "(cd daemon && swift build) so daemon/.build/debug/stard exists.",
                )
        }

        fun defaultScratchDir(): String =
            File(System.getProperty("user.home"), ".star-scratch").absolutePath

        private fun isWindows(): Boolean =
            System.getProperty("os.name").orEmpty().lowercase().contains("win")
    }
}
