package com.star.desktop.util

import java.nio.file.Files
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** H8: what the Debug window has to show. */
class LogBufferTest {
    private var savedLevel = Log.level

    @BeforeTest fun clean() { savedLevel = Log.level; LogBuffer.maxLines = LogBuffer.DEFAULT_MAX_LINES; LogBuffer.clear() }
    @AfterTest fun restore() { Log.level = savedLevel; LogBuffer.maxLines = LogBuffer.DEFAULT_MAX_LINES; LogBuffer.clear(); LogFile.stop() }

    private fun line(n: Int) = LogLine(n.toLong(), Log.Level.INFO, LogSource.CLIENT, "T", "line $n")

    @Test fun theOldestLinesGoWhenThereAreTooMany() {
        LogBuffer.maxLines = 3
        for (n in 1..5) LogBuffer.add(line(n))
        assertEquals(listOf("line 3", "line 4", "line 5"), LogBuffer.snapshot().map { it.message })
    }

    @Test fun loweringTheMaximumDropsTheOldestAtOnce() {
        for (n in 1..10) LogBuffer.add(line(n))
        LogBuffer.maxLines = 2
        assertEquals(listOf("line 9", "line 10"), LogBuffer.snapshot().map { it.message })
    }

    @Test fun theMaximumStaysInRange() {
        LogBuffer.maxLines = 0
        assertEquals(1, LogBuffer.maxLines)
        LogBuffer.maxLines = Int.MAX_VALUE
        assertEquals(LogBuffer.ABSOLUTE_MAX_LINES, LogBuffer.maxLines)
    }

    @Test fun clearingEmptiesItAndChangesTheVersion() {
        LogBuffer.add(line(1))
        val before = LogBuffer.version
        LogBuffer.clear()
        assertTrue(LogBuffer.snapshot().isEmpty())
        assertTrue(LogBuffer.version != before, "a window watching the version must see the clearing")
    }

    @Test fun everyChangeBumpsTheVersion() {
        val v0 = LogBuffer.version
        LogBuffer.add(line(1))
        val v1 = LogBuffer.version
        LogBuffer.add(line(2))
        assertTrue(v1 != v0 && LogBuffer.version != v1)
    }

    @Test fun theClipboardTextIsOneLineEach() {
        LogBuffer.add(LogLine(0, Log.Level.WARN, LogSource.ENGINE, "Session.swift:12", "low on memory"))
        LogBuffer.add(LogLine(0, Log.Level.INFO, LogSource.CLIENT, "App", "opened"))
        val lines = LogBuffer.rawText().split("\n")
        assertEquals(2, lines.size)
        assertTrue("stard Session.swift:12 low on memory" in lines[0], lines[0])
        assertTrue(Log.Level.WARN.emoji in lines[0])
        assertTrue("star-desktop App opened" in lines[1], lines[1])
    }

    @Test fun theEnginesOwnLineFormatIsTakenApart() {
        val l = LogBuffer.parseEngineLine("WARN | SessionManager.swift:39 init(config:): low on memory: 91%", 5)
        assertEquals(Log.Level.WARN, l.level)
        assertEquals(LogSource.ENGINE, l.source)
        assertEquals("SessionManager.swift:39 init(config:)", l.location)
        assertEquals("low on memory: 91%", l.message, "only the first colon and space split the location from the message")
        assertEquals(Log.Level.ERROR, LogBuffer.parseEngineLine("ERROR | a.swift:1: bad", 0).level)
        assertEquals(Log.Level.VERBOSE, LogBuffer.parseEngineLine("VERBOSE | a.swift:1: chatter", 0).level)
    }

    @Test fun aLineInNoKnownFormatIsKeptWhole() {
        val plain = LogBuffer.parseEngineLine("something odd on stderr", 0)
        assertEquals(Log.Level.INFO, plain.level)
        assertEquals("", plain.location)
        assertEquals("something odd on stderr", plain.message)
        assertEquals(Log.Level.ERROR, LogBuffer.parseEngineLine("*** star has crashed ***", 0).level)
        assertEquals(Log.Level.ERROR, LogBuffer.parseEngineLine("StarCore/x.swift:12: Fatal error: could not load", 0).level)
    }

    @Test fun whatTheClientLogsIsKeptAtOrAboveTheLevel() {
        Log.level = Log.Level.INFO
        Log.d("T") { "below" }
        Log.i("T") { "at" }
        Log.e("T") { "above" }
        assertEquals(listOf("at", "above"), LogBuffer.snapshot().map { it.message })
        assertTrue(LogBuffer.snapshot().all { it.source == LogSource.CLIENT && it.location == "T" })
    }

    @Test fun aMoreVerboseLevelKeepsMore() {
        Log.level = Log.Level.VERBOSE
        Log.v("T") { "very" }
        assertEquals(listOf("very"), LogBuffer.snapshot().map { it.message })
    }

    @Test fun theMessageIsNotBuiltWhenNothingWantsIt() {
        Log.level = Log.Level.ERROR
        var built = false
        Log.d("T") { built = true; "x" }
        assertFalse(built, "a disabled log line must cost nothing")
    }

    @Test fun aLogFileWrittenAtAMoreVerboseLevelThanTheWindowGetsTheLinesTheWindowDoesNot() {
        val dir = Files.createTempDirectory("star-logfile").toFile()
        try {
            Log.level = Log.Level.WARN
            val file = LogFile.start(Log.Level.DEBUG, dir)!!
            Log.d("T") { "debug line" }
            Log.w("T") { "warn line" }
            LogFile.stop()
            val text = file.readText()
            assertTrue("debug line" in text && "warn line" in text, text)
            assertEquals(listOf("warn line"), LogBuffer.snapshot().map { it.message }, "the window keeps only what its level shows")
            assertTrue(file.name.startsWith("star-desktop-") && file.name.endsWith(".log"), file.name)
        } finally {
            dir.deleteRecursively()
        }
    }

    @Test fun afterStoppingNothingMoreIsWritten() {
        val dir = Files.createTempDirectory("star-logfile").toFile()
        try {
            Log.level = Log.Level.ERROR
            val file = LogFile.start(Log.Level.INFO, dir)!!
            Log.i("T") { "first" }
            LogFile.stop()
            assertNull(LogFile.path)
            assertFalse(LogFile.wants(Log.Level.ERROR))
            Log.i("T") { "second" }
            assertEquals(listOf("[T/INFO] first"), file.readLines())
        } finally {
            dir.deleteRecursively()
        }
    }

    @Test fun aLogFileThatCannotBeOpenedIsNullAndHarmless() {
        val blocker = Files.createTempFile("star-notadir", "").toFile()
        try {
            assertNull(LogFile.start(Log.Level.INFO, java.io.File(blocker, "logs")))
            assertNull(LogFile.path)
        } finally {
            blocker.delete()
        }
    }

    @Test fun levelsAreSpokenOfByTheirWords() {
        assertEquals("verbose", Log.Level.VERBOSE.word)
        assertEquals(Log.Level.WARN, Log.Level.ofWord(" Warn "))
        assertNull(Log.Level.ofWord("loud"))
    }
}
