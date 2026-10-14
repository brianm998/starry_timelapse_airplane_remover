package com.star.desktop.ui.app

import com.star.desktop.util.Log
import com.star.desktop.util.LogFile
import com.star.proto.SetLogLevelResponse
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import java.io.File
import java.nio.file.Files
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** H8: the Debug window's choices reach both processes. */
class DebugLogSettingsTest {
    private class Call(val level: String, val fileEnabled: Boolean?, val fileLevel: String)

    private val calls = ArrayList<Call>()
    private var engineFile: String = ""
    private var engineThere = true
    private lateinit var dir: File
    private var savedLevel = Log.level

    @BeforeTest fun setUp() { savedLevel = Log.level; dir = Files.createTempDirectory("star-debug").toFile() }
    @AfterTest fun tearDown() { Log.level = savedLevel; LogFile.stop(); dir.deleteRecursively() }

    // Unconfined: what is launched runs before the call returns, so the test needs no waiting.
    private fun settings() = DebugLogSettings(
        CoroutineScope(SupervisorJob() + Dispatchers.Unconfined),
        tellEngine = { level, fileEnabled, fileLevel ->
            calls += Call(level, fileEnabled, fileLevel)
            if (!engineThere) null
            else SetLogLevelResponse.newBuilder().setLevel(level).setFileLogPath(engineFile).build()
        },
        logsDirectory = { dir },
    )

    @Test fun aLevelChosenIsTheClientsAndIsToldToTheEngine() {
        val s = settings()
        s.setLevel(Log.Level.DEBUG)
        assertEquals(Log.Level.DEBUG, Log.level)
        assertEquals(Log.Level.DEBUG, s.level.value)
        assertEquals("debug", calls.single().level)
        assertNull(calls.single().fileEnabled, "the level alone is sent, the file is not touched")
    }

    @Test fun switchingTheFileOnStartsTheClientsAndAsksTheEnginesAtTheFilesLevel() {
        engineFile = "/scratch/logs/stard-2026.txt"
        val s = settings()
        s.setFileLevel(Log.Level.DEBUG)
        calls.clear()
        s.setFileEnabled(true)
        val client = assertNotNull(s.clientFile.value)
        assertTrue(client.parentFile == dir && client.exists())
        assertEquals("/scratch/logs/stard-2026.txt", s.engineFile.value)
        assertEquals(true, calls.single().fileEnabled)
        assertEquals("debug", calls.single().fileLevel)
        assertTrue(LogFile.wants(Log.Level.DEBUG))
    }

    @Test fun switchingTheFileOffStopsBothAndForgetsTheNames() {
        engineFile = "/scratch/logs/stard-2026.txt"
        val s = settings()
        s.setFileEnabled(true)
        engineFile = ""
        s.setFileEnabled(false)
        assertNull(s.clientFile.value)
        assertNull(s.engineFile.value)
        assertFalse(s.fileEnabled.value)
        assertNull(LogFile.path)
        assertEquals(false, calls.last().fileEnabled)
    }

    @Test fun theFilesLevelCanChangeWhileItIsOn() {
        engineFile = "/e.txt"
        val s = settings()
        s.setFileEnabled(true)
        s.setFileLevel(Log.Level.VERBOSE)
        assertEquals(Log.Level.VERBOSE, s.fileLevel.value)
        assertTrue(LogFile.wants(Log.Level.VERBOSE))
        assertEquals("verbose", calls.last().fileLevel)
        assertNull(calls.last().fileEnabled)
        assertEquals("/e.txt", s.engineFile.value, "the engine's file is the same one")
    }

    @Test fun noEngineMeansTheClientAloneChanges() {
        engineThere = false
        val s = settings()
        s.setLevel(Log.Level.WARN)
        s.setFileEnabled(true)
        assertEquals(Log.Level.WARN, Log.level)
        assertNotNull(s.clientFile.value)
        assertNull(s.engineFile.value)
    }

    @Test fun aFreshEngineIsToldWhatWasChosenButNotWhenNothingWas() {
        val s = settings()
        s.reapplyToEngine()
        assertTrue(calls.isEmpty(), "the defaults are the engine's own: nothing to say")

        s.setLevel(Log.Level.DEBUG)
        s.setFileEnabled(true)
        calls.clear()
        s.reapplyToEngine()
        val said = calls.single()
        assertEquals("debug", said.level)
        assertEquals(true, said.fileEnabled)
    }

    @Test fun aFreshEngineIsNotToldAFileWhenThereIsNone() {
        val s = settings()
        s.setLevel(Log.Level.ERROR)
        calls.clear()
        s.reapplyToEngine()
        assertEquals("error", calls.single().level)
        assertNull(calls.single().fileEnabled)
    }
}
