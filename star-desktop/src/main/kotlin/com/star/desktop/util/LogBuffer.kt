package com.star.desktop.util

import java.text.SimpleDateFormat
import java.util.Date

/** Which process a line of the log came from. */
enum class LogSource(val process: String) { CLIENT("star-desktop"), ENGINE("stard") }

/** One line of the log: when, how severe, who said it, where in their code, and what. */
data class LogLine(val timeMillis: Long, val level: Log.Level, val source: LogSource, val location: String, val message: String) {
    /** The line as the Debug window shows it, and as Copy to Clipboard copies it. */
    fun text(): String = "${TIME_FORMAT.get().format(Date(timeMillis))} ${level.emoji} ${source.process} ${location.ifEmpty { "-" }} $message"

    private companion object {
        val TIME_FORMAT: ThreadLocal<SimpleDateFormat> = ThreadLocal.withInitial { SimpleDateFormat("H:mm:ss.SSS") }
    }
}

/**
 * The most recent lines of the log, from this process and from the engine's stderr, for the Debug window (macOS `LoggingViewModel.logs`). A
 * bounded ring: the oldest line goes when [maxLines] is exceeded, so a long run at a verbose level cannot fill memory.
 */
object LogBuffer {
    private val lines = ArrayDeque<LogLine>()
    private val lock = Any()

    /** Most lines kept; lowering it drops the oldest at once. */
    var maxLines: Int = DEFAULT_MAX_LINES
        set(value) {
            synchronized(lock) {
                field = value.coerceIn(1, ABSOLUTE_MAX_LINES)
                trim()
            }
        }

    /** Bumped on every change, so a window can tell whether there is anything new without copying the lines. */
    @Volatile var version: Long = 0
        private set

    fun add(line: LogLine) {
        synchronized(lock) {
            lines.addLast(line)
            trim()
            version++
        }
    }

    fun snapshot(): List<LogLine> = synchronized(lock) { lines.toList() }

    fun clear() = synchronized(lock) { lines.clear(); version++ }

    /** Every line, one to a line of text (Copy to Clipboard). */
    fun rawText(): String = snapshot().joinToString("\n") { it.text() }

    private fun trim() {
        while (lines.size > maxLines) lines.removeFirst()
    }

    /** A line the engine wrote to stderr, in the log. The engine's own format is parsed; anything else (a crash report, Swift's own text) is kept as it came. */
    fun addEngineLine(raw: String, now: Long = System.currentTimeMillis()) = add(parseEngineLine(raw, now))

    /**
     * The engine's stderr format is `LEVEL | file.swift:line function: message` (`StderrLogHandler`). A line in no such format is kept whole, as
     * an error if it says Swift trapped or the engine crashed, and as information otherwise.
     */
    fun parseEngineLine(raw: String, now: Long): LogLine {
        val m = ENGINE_LINE.matchEntire(raw)
        if (m != null) {
            val level = Log.Level.ofWord(m.groupValues[1]) ?: Log.Level.INFO
            return LogLine(now, level, LogSource.ENGINE, m.groupValues[2], m.groupValues[3])
        }
        val level = if ("Fatal error" in raw || "crashed" in raw) Log.Level.ERROR else Log.Level.INFO
        return LogLine(now, level, LogSource.ENGINE, "", raw)
    }

    const val DEFAULT_MAX_LINES = 2000
    const val ABSOLUTE_MAX_LINES = 1_000_000

    private val ENGINE_LINE = Regex("""^(VERBOSE|DEBUG|INFO|WARN|ERROR) \| (.*?): (.*)$""")
}
