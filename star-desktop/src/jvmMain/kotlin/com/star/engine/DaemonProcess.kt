package com.star.engine

import kotlinx.coroutines.*
import java.io.File
import java.io.InputStream
import java.io.OutputStream

/**
 * Spawns and supervises the stard child process.
 * Owns its three streams: stdin (client→daemon), stdout (daemon→client), stderr (daemon logs).
 * See CROSS_PLATFORM_DAEMON_DESIGN.md §4 and KOTLIN_CLIENT_SPEC.md §2.1.
 */
class DaemonProcess(
    private val binaryPath: String,
    private val scratchDir: String,
    private val logFile: String? = null,
) {
    private var process: Process? = null
    private var stderrJob: Job? = null

    val stdin: OutputStream get() = process?.outputStream ?: error("daemon not started")
    val stdout: InputStream get() = process?.inputStream ?: error("daemon not started")

    fun start(logScope: CoroutineScope) {
        val args = buildList {
            add(binaryPath)
            add("--scratch")
            add(scratchDir)
            logFile?.let { add("--log-file"); add(it) }
        }
        val proc = ProcessBuilder(args)
            .redirectErrorStream(false)
            .start()
        process = proc

        // Drain stderr to the app log; never parse as protocol.
        stderrJob = logScope.launch(Dispatchers.IO) {
            proc.errorStream.bufferedReader().forEachLine { line ->
                println("[stard] $line")
            }
        }
    }

    fun isAlive(): Boolean = process?.isAlive == true

    suspend fun waitFor(): Int = withContext(Dispatchers.IO) { process?.waitFor() ?: -1 }

    fun destroy() {
        stderrJob?.cancel()
        process?.destroy()
        process = null
    }

    companion object {
        /**
         * Resolve the stard binary relative to the app executable or in developer build trees.
         * On distribution builds, stard is bundled next to the app jar/exe.
         */
        fun resolveStardBinary(): String {
            val execDir = try {
                File(DaemonProcess::class.java.protectionDomain.codeSource.location.toURI()).parentFile
            } catch (_: Exception) {
                null
            }

            val candidates = buildList {
                if (execDir != null) {
                    add(File(execDir, "stard"))
                    add(File(execDir, "stard.exe"))
                    add(File(execDir.parentFile ?: execDir, "stard"))
                    add(File(execDir.parentFile ?: execDir, "stard.exe"))
                }
                // Developer paths: look in daemon build output
                add(File("../daemon/.build/debug/stard"))
                add(File("../daemon/.build/release/stard"))
                add(File("daemon/.build/debug/stard"))
                add(File("daemon/.build/release/stard"))
            }

            return candidates.firstOrNull { it.exists() && it.canExecute() }?.absolutePath
                ?: error(
                    "stard binary not found. Build the daemon target and place it next to the app, " +
                        "or build at ../daemon/.build/debug/stard"
                )
        }

        fun defaultScratchDir(): String {
            val home = System.getProperty("user.home")
            return "$home/.star-scratch"
        }
    }
}
