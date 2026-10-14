package com.star.desktop.util

/**
 * Minimal leveled logger to stderr, with what it logs also kept for the Debug window ([LogBuffer]) and, when the user has switched it on,
 * written to a file ([LogFile]). Keeps the client off `stdout` entirely (which is reserved for nothing in the client, but disciplined logging
 * avoids the v1 client's scattered `println` spew).
 */
object Log {
    /** Least to most severe, as the macOS `Log.Level` and the engine's, with the emoji the macOS Debug window shows beside each. */
    enum class Level(val emoji: String) {
        VERBOSE("💦"), DEBUG("👩‍💻"), INFO("🚩"), WARN("⚠️"), ERROR("☠️");

        /** The word the level is spoken of by, to the engine (`Daemon.SetLogLevel`) and in pickers: verbose, debug, info, warn, error. */
        val word: String get() = name.lowercase()

        companion object {
            fun ofWord(word: String): Level? = entries.firstOrNull { it.word == word.trim().lowercase() }
        }
    }

    /** What is shown in the Debug window and written to stderr: this level and above. */
    @Volatile var level: Level = Level.INFO

    fun v(tag: String, msg: () -> String) = log(Level.VERBOSE, tag, msg)
    fun d(tag: String, msg: () -> String) = log(Level.DEBUG, tag, msg)
    fun i(tag: String, msg: () -> String) = log(Level.INFO, tag, msg)
    fun w(tag: String, msg: () -> String) = log(Level.WARN, tag, msg)
    fun e(tag: String, t: Throwable? = null, msg: () -> String) {
        log(Level.ERROR, tag, msg)
        t?.let { System.err.println(it.stackTraceToString()) }
    }

    private inline fun log(lvl: Level, tag: String, msg: () -> String) {
        val shown = lvl.ordinal >= level.ordinal
        val filed = LogFile.wants(lvl)
        if (!shown && !filed) return
        val text = msg()
        val line = "[$tag/${lvl.name}] $text"
        if (shown) {
            System.err.println(line)
            LogBuffer.add(LogLine(System.currentTimeMillis(), lvl, LogSource.CLIENT, tag, text))
        }
        if (filed) LogFile.write(line)
    }
}
