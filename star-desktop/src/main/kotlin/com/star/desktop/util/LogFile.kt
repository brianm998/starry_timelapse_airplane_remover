package com.star.desktop.util

import java.io.File
import java.io.Writer
import java.text.SimpleDateFormat
import java.util.Date

/**
 * The client's own log file, which the user switches on in the Debug window (macOS "Log to file at level"): everything this process logs at
 * or above a level, written as it happens to a file of its own, so that it can be sent in a report.
 */
object LogFile {
    private var writer: Writer? = null

    /** The file being written, or null when none is. */
    @Volatile var path: File? = null
        private set

    @Volatile private var fileLevel: Log.Level = Log.Level.INFO

    /** Whether a line at [level] would be written (so that [Log] knows to build it). */
    fun wants(level: Log.Level): Boolean = path != null && level.ordinal >= fileLevel.ordinal

    /** Start a new file in [directory], writing [level] and above. Returns it, or null if it could not be opened (the log goes on without). */
    @Synchronized fun start(level: Log.Level, directory: File): File? {
        stop()
        return try {
            directory.mkdirs()
            val name = "star-desktop-" + SimpleDateFormat("yyyy-MM-dd-HH-mm-ss").format(Date()) + ".log"
            val file = File(directory, name)
            writer = file.bufferedWriter()
            fileLevel = level
            path = file
            file
        } catch (e: Exception) {
            System.err.println("[LogFile/ERROR] could not open a log file in $directory: ${e.message}")
            null
        }
    }

    /** Write at another level to the same file. */
    @Synchronized fun setLevel(level: Log.Level) { fileLevel = level }

    @Synchronized fun stop() {
        path = null
        runCatching { writer?.close() }
        writer = null
    }

    @Synchronized fun write(line: String) {
        val w = writer ?: return
        try {
            w.appendLine(line)
            w.flush()
        } catch (e: Exception) {
            stop()
        }
    }
}
