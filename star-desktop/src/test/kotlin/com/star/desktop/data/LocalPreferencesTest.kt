package com.star.desktop.data

import java.io.File
import java.nio.file.Files
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * `~/.star.userprefs.json` is written by BOTH clients — this one by hand through Gson, the macOS
 * app through Codable synthesis over `UserPreferences.swift`. Two things have to hold for the
 * moving-horizon multiplier to survive a machine with both installed: the key has to be spelled the
 * way Swift spells its property, and a save from this side must not drop what the other side wrote.
 *
 * That second one is the sharp edge. Every save rewrites the whole file from this class's fields,
 * so a key that fails to load is a key that gets DELETED on the next unrelated save — which is why
 * unknown keys are kept aside in `others` and why the load path is worth pinning.
 *
 * The tests point `user.home` at a temp directory: `LocalPreferences` resolves the file when it is
 * constructed, so this redirects it without going near the real preferences of whoever runs them.
 */
class LocalPreferencesTest {

    private lateinit var home: File
    private var savedHome: String? = null

    private val prefsFile: File get() = File(home, ".star.userprefs.json")

    @BeforeTest fun redirectHome() {
        savedHome = System.getProperty("user.home")
        home = Files.createTempDirectory("star-prefs-test").toFile()
        System.setProperty("user.home", home.absolutePath)
    }

    @AfterTest fun restoreHome() {
        savedHome?.let { System.setProperty("user.home", it) } ?: System.clearProperty("user.home")
        home.deleteRecursively()
    }

    @Test fun noPreferencesFileMeansNoRecordedMultiplier() {
        assertNull(LocalPreferences().movingHorizonCountMultiplier)
    }

    @Test fun preferencesWrittenBeforeThisFeatureStillLoad() {
        prefsFile.writeText("""{"recentlyOpenedSequencelist":{},"skipRenderPromptAfterProcessing":true}""")
        val prefs = LocalPreferences()
        assertNull(prefs.movingHorizonCountMultiplier)
        assertEquals(true, prefs.skipRenderPromptAfterProcessing)
    }

    @Test fun theMultiplierRoundTripsThroughTheFile() {
        LocalPreferences().setMovingHorizonCountMultiplier(1.5)
        assertTrue(prefsFile.readText().contains("movingHorizonCountMultiplier"), prefsFile.readText())
        assertEquals(1.5, LocalPreferences().movingHorizonCountMultiplier)
    }

    /**
     * The key, and the number forms, the macOS app's `UserPreferences.movingHorizonCountMultiplier`
     * actually encodes to — captured from Swift's `JSONEncoder`, which drops the fraction on a whole
     * multiplier and writes `2`, not `2.0`. Gson hands every JSON number back as a Double, so the
     * plain `as? Double` here covers it; a stricter reader would not.
     */
    @Test fun aMultiplierWrittenByTheSwiftAppIsRead() {
        prefsFile.writeText("""{"recentlyOpenedSequencelist":{},"movingHorizonCountMultiplier":2.5}""")
        assertEquals(2.5, LocalPreferences().movingHorizonCountMultiplier)

        prefsFile.writeText("""{"recentlyOpenedSequencelist":{},"movingHorizonCountMultiplier":2}""")
        assertEquals(2.0, LocalPreferences().movingHorizonCountMultiplier)

        prefsFile.writeText("""{"recentlyOpenedSequencelist":{},"movingHorizonCountMultiplier":0.3333333333333333}""")
        assertEquals(1.0 / 3.0, LocalPreferences().movingHorizonCountMultiplier)
    }

    /** A save for some unrelated reason must not throw away what the other client recorded. */
    @Test fun anUnrelatedSaveKeepsTheMultiplier() {
        prefsFile.writeText("""{"recentlyOpenedSequencelist":{},"movingHorizonCountMultiplier":2.5}""")
        val prefs = LocalPreferences()
        prefs.setSkipRenderPrompt(true)
        assertEquals(2.5, LocalPreferences().movingHorizonCountMultiplier)
    }

    /** Nor may it throw away keys only the Swift app knows about. */
    @Test fun anUnrelatedSaveKeepsKeysOnlyTheSwiftAppWrites() {
        prefsFile.writeText("""{"recentlyOpenedSequencelist":{},"frameRate":"fps_24"}""")
        LocalPreferences().setMovingHorizonCountMultiplier(2.0)
        assertTrue(prefsFile.readText().contains("frameRate"), prefsFile.readText())
    }

    /** A hand-edited or future-written file must not be able to produce a nonsense suggestion. */
    @Test fun aNonsenseMultiplierIsIgnored() {
        for (bad in listOf("0", "-2.0", "\"nope\"", "null")) {
            prefsFile.writeText("""{"recentlyOpenedSequencelist":{},"movingHorizonCountMultiplier":$bad}""")
            assertNull(LocalPreferences().movingHorizonCountMultiplier, "should have ignored $bad")
        }
    }
}
