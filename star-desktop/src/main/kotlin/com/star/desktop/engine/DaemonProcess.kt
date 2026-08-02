package com.star.desktop.engine

import com.star.desktop.util.Log
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

    /** The last few stderr lines, kept so a death can be explained rather than just reported. */
    private val recentStderr = ArrayDeque<String>()
    private val stderrLock = Any()

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
            proc.errorStream.bufferedReader().forEachLine { line ->
                synchronized(stderrLock) {
                    recentStderr.addLast(line)
                    while (recentStderr.size > STDERR_TAIL) recentStderr.removeFirst()
                }
                onStderrLine(line)
            }
        }
    }

    fun isAlive(): Boolean = process?.isAlive == true

    fun exitValueOrNull(): Int? = try {
        process?.exitValue()
    } catch (_: IllegalThreadStateException) {
        null // still running
    }

    /** The last stderr lines the daemon produced, oldest first. */
    fun stderrTail(): List<String> = synchronized(stderrLock) { recentStderr.toList() }

    /**
     * Why the daemon is gone, in a sentence, or null if it is still running.
     *
     * The exit status is the useful part and was being thrown away: `exitValueOrNull()` existed
     * but nothing ever called it, so a daemon killed by the OS and a daemon that quit normally
     * were reported to the user identically, as "engine stopped". On Unix a process killed by
     * signal N exits with 128+N, so 137 is SIGKILL — which for stard almost always means the
     * system ran out of memory, exactly the failure the whole crash-reporting effort is about.
     */
    fun deathDescription(): String? {
        val code = exitValueOrNull() ?: return null

        val cause = when (code) {
            0 -> "the engine exited normally"
            137 -> "the engine was killed by the system (SIGKILL) — most likely out of memory"
            143 -> "the engine was asked to stop (SIGTERM)"
            139 -> "the engine crashed (SIGSEGV)"
            134 -> "the engine crashed (SIGABRT)"
            138 -> "the engine crashed (SIGBUS)"
            133 -> "the engine crashed (SIGTRAP)"
            in 129..192 -> "the engine was killed by signal ${code - 128}"
            else -> "the engine exited with status $code"
        }

        // The daemon's own last words, when it managed any. Its crash handler writes a
        // "*** star has crashed ***" block to stderr, and StarWarnings writes memory-pressure
        // warnings there too, so the tail usually says more than the exit code alone.
        val detail = stderrTail()
            .filter { it.isNotBlank() }
            .lastOrNull { it.contains("STAR-WARNING") || it.contains("ERROR") || it.contains("crashed") }

        return if (detail != null) "$cause — $detail" else cause
    }

    fun destroy() {
        stderrJob?.cancel()
        runCatching { process?.outputStream?.close() } // close stdin → daemon gets EOF (clean-exit backstop, design §2.1)
        process?.destroy()
        process = null
    }

    companion object {
        /** How many stderr lines to keep for [deathDescription]. */
        private const val STDERR_TAIL = 50

        /**
         * Resolve the `stard` binary. Precedence:
         *  1. `-Dstar.stard.path=...` system property (dev override),
         *  2. `STARD_PATH` env var,
         *  3. the packaged distribution's bundled resources (`compose.application.resources.dir`,
         *     where `stageAppResources` placed stard alongside ffmpeg/ffprobe),
         *  4. next to the app executable (distribution bundle),
         *  5. developer build trees, RELEASE preferred over debug (daemon/.build/{release,debug}/stard
         *     relative to common roots). Debug stard runs the StarCore pipeline ~5-10x slower and is never
         *     debugged under this client, so a debug fallback is allowed but warned about loudly.
         */
        fun resolveStardBinary(): String {
            System.getProperty("star.stard.path")?.let { if (File(it).canExecute()) return it }
            System.getenv("STARD_PATH")?.let { if (File(it).canExecute()) return it }

            val execDir = runCatching {
                File(DaemonProcess::class.java.protectionDomain.codeSource.location.toURI()).parentFile
            }.getOrNull()

            val exeName = if (isWindows()) "stard.exe" else "stard"
            val candidates = buildList {
                // Packaged app: Compose stages the native binaries (stard + ffmpeg/ffprobe) here.
                System.getProperty("compose.application.resources.dir")?.let { add(File(it, exeName)) }
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
            val resolved = candidates.firstOrNull { it.exists() && it.canExecute() }?.absolutePath
                ?: error(
                    "stard binary not found. Set -Dstar.stard.path=/path/to/stard, or build the daemon " +
                        "(cd daemon && swift build -c release) so daemon/.build/release/stard exists.",
                )
            if (resolved.replace(File.separatorChar, '/').contains("/.build/debug/")) {
                Log.w("Daemon") {
                    "using a DEBUG stard at $resolved — the StarCore pipeline runs ~5-10x slower here. " +
                        "Build release instead: (cd daemon && swift build -c release)"
                }
            }
            return resolved
        }

        fun defaultScratchDir(): String =
            File(System.getProperty("user.home"), ".star-scratch").absolutePath

        private fun isWindows(): Boolean =
            System.getProperty("os.name").orEmpty().lowercase().contains("win")
    }
}
