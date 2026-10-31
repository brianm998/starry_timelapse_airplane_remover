package com.star.desktop.data

import com.star.desktop.domain.GpuToggle
import java.io.File
import java.nio.file.Files
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
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

    /** The GPU toggles are the macOS app's `useGPUForMerge` / `useGPUForSIFT` / `useGPUForAKAZE`: same keys, nothing until the user chooses. */
    @Test fun gpuChoicesAreUnsetUntilTheUserMakesOne() {
        val prefs = LocalPreferences()
        GpuToggle.entries.forEach { assertNull(prefs.gpu(it), "$it") }
        // an old file with none of them reads the same, and reading it writes nothing
        prefsFile.writeText("""{"recentlyOpenedSequencelist":{}}""")
        GpuToggle.entries.forEach { assertNull(LocalPreferences().gpu(it), "$it") }
        assertTrue(!prefsFile.readText().contains("useGPU"), prefsFile.readText())
    }

    /** Turned off has to survive as off: it is the one value that looks like "absent" to a careless reader. */
    @Test fun aGpuChoiceOfOffRoundTripsAsOff() {
        LocalPreferences().apply { setGpu(GpuToggle.SIFT, false); setGpu(GpuToggle.MERGE, true) }
        assertTrue(prefsFile.readText().contains("\"useGPUForSIFT\":false"), prefsFile.readText())
        val reloaded = LocalPreferences()
        assertEquals(false, reloaded.gpu(GpuToggle.SIFT))
        assertEquals(true, reloaded.gpu(GpuToggle.MERGE))
        assertNull(reloaded.gpu(GpuToggle.AKAZE))
    }

    @Test fun gpuChoicesTheSwiftAppWroteAreRead() {
        prefsFile.writeText("""{"recentlyOpenedSequencelist":{},"useGPUForMerge":false,"useGPUForSIFT":true}""")
        val prefs = LocalPreferences()
        assertEquals(false, prefs.gpu(GpuToggle.MERGE))
        assertEquals(true, prefs.gpu(GpuToggle.SIFT))
        assertNull(prefs.gpu(GpuToggle.AKAZE))
    }

    /** A choice made here must not cost the other client its own keys, nor an unrelated save this one's choice. */
    @Test fun gpuChoicesAndOtherKeysSurviveEachOthersSaves() {
        prefsFile.writeText("""{"recentlyOpenedSequencelist":{},"frameRate":"fps_24"}""")
        LocalPreferences().setGpu(GpuToggle.AKAZE, false)
        assertTrue(prefsFile.readText().contains("frameRate"), prefsFile.readText())
        LocalPreferences().setSkipRenderPrompt(true)
        assertEquals(false, LocalPreferences().gpu(GpuToggle.AKAZE))
    }

    /** A hand-edited or future-written file must not be able to produce a nonsense suggestion. */
    @Test fun aNonsenseMultiplierIsIgnored() {
        for (bad in listOf("0", "-2.0", "\"nope\"", "null")) {
            prefsFile.writeText("""{"recentlyOpenedSequencelist":{},"movingHorizonCountMultiplier":$bad}""")
            assertNull(LocalPreferences().movingHorizonCountMultiplier, "should have ignored $bad")
        }
    }

    // ---- recent files: shared with the macOS app, which opens every entry as a session's config.json ----

    /** [text] as a JSON string literal: a Windows path is full of backslashes, which a hand-quoted one would leave as invalid escapes. */
    private fun json(text: String): String = com.google.gson.Gson().toJson(text)

    private fun recentInFile(): Map<*, *> {
        val parsed = com.google.gson.Gson().fromJson(prefsFile.readText(), Map::class.java)
        return parsed["recentlyOpenedSequencelist"] as Map<*, *>
    }

    /** The file holds everything the other app recorded: this client lists 20 but must not delete the rest. */
    @Test fun theRecentListIsNotTrimmedOnWrite() {
        val real = (1..25).map { File(home, "session$it.json").also { f -> f.writeText("{}") }.path }
        val prefs = LocalPreferences()
        real.forEach { prefs.addRecentFile(it) }
        assertEquals(25, recentInFile().size, "older entries were deleted from the shared file")
        assertEquals(20, prefs.recentFiles.size, "this client's own list is still capped")
    }

    /** What the macOS app does on load: an entry whose file is gone can only fail to open. */
    @Test fun recentEntriesWhoseFileIsGoneAreForgottenOnLoad() {
        val kept = File(home, "kept.json").also { it.writeText("{}") }
        prefsFile.writeText(
            """{"recentlyOpenedSequencelist":{${json(kept.path)}:10.0,${json("${home.path}/gone.json")}:20.0},"language":"fr"}""",
        )
        val prefs = LocalPreferences()
        assertEquals(listOf(kept.path), prefs.recentFiles)
        assertTrue(!prefsFile.readText().contains("gone.json"), "the pruned entry is still in the file")
        assertEquals("fr", LocalPreferences().language, "pruning cost another key")
    }

    /** A change the other app makes while this one is running must survive this one's next save. */
    @Test fun aSaveDoesNotUndoWhatTheOtherAppWroteMeanwhile() {
        val a = File(home, "a.json").also { it.writeText("{}") }
        val b = File(home, "b.json").also { it.writeText("{}") }
        val prefs = LocalPreferences()
        prefs.addRecentFile(a.path)

        // The macOS app opens something and turns a setting on, after this client started.
        prefsFile.writeText(
            """{"recentlyOpenedSequencelist":{${json(a.path)}:5.0,${json(b.path)}:9999999999.0},"showHorizonOnMainView":true}""",
        )
        prefs.setLanguage("de")

        val text = prefsFile.readText()
        assertTrue(text.contains("showHorizonOnMainView"), text)
        assertTrue(recentInFile().containsKey(b.path), "the other app's recent entry was overwritten: $text")
        assertEquals("de", LocalPreferences().language)
    }

    @Test fun startingWithNoFileWritesNoFile() {
        LocalPreferences()
        assertTrue(!prefsFile.exists(), "a preferences file appeared just from starting")
    }
}

class LocalPreferencesBooleansTest {
    private lateinit var home: File
    private var savedHome: String? = null
    private val prefsFile: File get() = File(home, ".star.userprefs.json")

    @BeforeTest fun redirectHome() {
        savedHome = System.getProperty("user.home")
        home = Files.createTempDirectory("star-prefs-bool-test").toFile()
        System.setProperty("user.home", home.absolutePath)
    }

    @AfterTest fun restoreHome() {
        savedHome?.let { System.setProperty("user.home", it) } ?: System.clearProperty("user.home")
        home.deleteRecursively()
    }

    /** macOS reads a missing key as "yes, show it": the instructions are on until the user says otherwise. */
    @Test fun theHorizonPainterInstructionsAreOnUntilTurnedOff() {
        assertTrue(LocalPreferences().showHorizonPainterInstructions)
    }

    @Test fun turningThemOffIsRememberedUnderTheMacOSKey() {
        LocalPreferences().showHorizonPainterInstructions = false
        assertTrue(prefsFile.readText().contains("\"showHorizonPainterInstructions\":false"), prefsFile.readText())
        assertEquals(false, LocalPreferences().showHorizonPainterInstructions)
    }

    /** Every kind of horizon line is drawn until the user hides one, and the choice is the macOS app's key and raw values. */
    @Test fun hiddenHorizonLineKindsRoundTripUnderTheMacOSKey() {
        assertEquals(emptyList(), LocalPreferences().hiddenHorizonLineKinds)
        LocalPreferences().hiddenHorizonLineKinds = listOf("merged", "initial", "merged")
        assertTrue(prefsFile.readText().contains("\"hiddenHorizonLineKinds\":[\"initial\",\"merged\"]"), prefsFile.readText())
        assertEquals(listOf("initial", "merged"), LocalPreferences().hiddenHorizonLineKinds)
    }

    /** The processing screen's charts: off until turned on, under the macOS app's own key so the two clients share the choice. */
    @Test fun theProcessingWindowsAlignmentChartsAreOffUntilTurnedOn() {
        assertFalse(LocalPreferences().showAlignmentInProcessingWindow)
        LocalPreferences().showAlignmentInProcessingWindow = true
        assertTrue(prefsFile.readText().contains("\"showAlignmentInProcessingWindow\":true"), prefsFile.readText())
        assertEquals(true, LocalPreferences().showAlignmentInProcessingWindow)
        LocalPreferences().showAlignmentInProcessingWindow = false
        assertTrue(prefsFile.readText().contains("\"showAlignmentInProcessingWindow\":false"), prefsFile.readText())
        assertEquals(false, LocalPreferences().showAlignmentInProcessingWindow)
    }

    /** What the Render Video dialog last chose is kept under the Mac app's keys, in the shape its coding gives them, so either app opens with it. */
    @Test fun theRenderChoicesAreKeptTheWayTheMacKeepsThem() {
        val p = LocalPreferences()
        assertEquals(null, p.videoFrameRate)
        p.videoFrameRate = 29.97
        p.videoCodec = "h264"
        p.videoEncoder = "libx264"
        p.videoPixelFormat = "yuv420p"
        p.videoMuxer = "mov"
        val text = prefsFile.readText()
        assertTrue(text.contains("\"frameRate\":{\"fps_29_97\":{}}"), text)
        assertTrue(text.contains("\"codec\":\"h264\"") && text.contains("\"encoder\":\"libx264\"") && text.contains("\"pixelFormat\":\"yuv420p\"") && text.contains("\"muxer\":\"mov\""), text)

        val again = LocalPreferences()
        assertEquals(29.97, again.videoFrameRate)
        assertEquals("h264", again.videoCodec)
        assertEquals("libx264", again.videoEncoder)
        assertEquals("yuv420p", again.videoPixelFormat)
        assertEquals("mov", again.videoMuxer)
    }

    @Test fun aRateTheMacWroteIsReadByThisClient() {
        prefsFile.writeText("""{"frameRate":{"custom":{"_0":12.5}},"codec":"prores"}""")
        val p = LocalPreferences()
        assertEquals(12.5, p.videoFrameRate)
        assertEquals("prores", p.videoCodec)
        assertEquals(null, p.videoMuxer)
    }

    /** The processing screen is on until the user turns it off, under the Mac app's key. */
    @Test fun theProcessingWindowIsOnUntilTurnedOff() {
        assertTrue(LocalPreferences().showProcessingWindow)
        LocalPreferences().showProcessingWindow = false
        assertTrue(prefsFile.readText().contains("\"showProcessingWindow\":false"), prefsFile.readText())
        assertEquals(false, LocalPreferences().showProcessingWindow)
        LocalPreferences().showProcessingWindow = true
        assertTrue(LocalPreferences().showProcessingWindow)
    }

    /** The render prompt's "don't ask again" could not be undone; the Preferences switch is the way back. */
    @Test fun theRenderPromptCanBeAskedAgain() {
        val p = LocalPreferences()
        p.setSkipRenderPrompt(true)
        assertTrue(LocalPreferences().skipRenderPromptAfterProcessing)
        p.setSkipRenderPrompt(false)
        assertEquals(false, LocalPreferences().skipRenderPromptAfterProcessing)
    }

    @Test fun turningThemBackOnWorks() {
        val p = LocalPreferences()
        p.showHorizonPainterInstructions = false
        p.showHorizonPainterInstructions = true
        assertTrue(LocalPreferences().showHorizonPainterInstructions)
    }

    /** What the macOS app wrote is read, and a key this client has no property for can still be asked for. */
    @Test fun aBooleanTheMacOSAppWroteIsRead() {
        prefsFile.writeText("""{"recentlyOpenedSequencelist":{},"showHorizonOnMainView":true}""")
        val p = LocalPreferences()
        assertEquals(true, p.bool("showHorizonOnMainView"))
        assertEquals(null, p.bool("never set"))
    }

    @Test fun forgettingABooleanRemovesTheKeySoMacOSSeesItsDefault() {
        val p = LocalPreferences()
        p.setBool("showProcessingWindow", false)
        p.setBool("showProcessingWindow", null)
        assertTrue(!prefsFile.readText().contains("showProcessingWindow"), prefsFile.readText())
    }

    /** macOS reads a missing showHorizonOnMainView as off. */
    @Test fun theHorizonLineIsOffUntilTurnedOnAndRemembered() {
        assertEquals(false, LocalPreferences().showHorizonOnMainView)
        val p = LocalPreferences()
        p.showHorizonOnMainView = true
        assertTrue(prefsFile.readText().contains("\"showHorizonOnMainView\":true"), prefsFile.readText())
        assertEquals(true, LocalPreferences().showHorizonOnMainView)
    }

    // M1 of the parity plan: a file that does not parse is the user's to fix, never ours to overwrite.

    private val garbage = """{"language": "de", """

    @Test fun anUnreadableFileIsLeftAloneWhenAPreferenceChanges() {
        prefsFile.writeText(garbage)
        val p = LocalPreferences()
        p.setBool("showProcessingWindow", false)
        p.setLanguage("fr")
        assertEquals(garbage, prefsFile.readText())
    }

    @Test fun aCopyOfTheUnreadableFileIsKeptBesideIt() {
        prefsFile.writeText(garbage)
        LocalPreferences()
        val copy = File(prefsFile.path + ".undecodable")
        assertTrue(copy.exists(), "no .undecodable copy")
        assertEquals(garbage, copy.readText())
    }

    @Test fun theCopyIsNotReplacedByALaterUnreadableFile() {
        prefsFile.writeText(garbage)
        LocalPreferences()
        prefsFile.writeText("""[1, 2""")
        LocalPreferences()
        assertEquals(garbage, File(prefsFile.path + ".undecodable").readText())
    }

    /** The session still works: a changed preference takes effect, it just is not written down. */
    @Test fun aPreferenceChangedOverAnUnreadableFileStillHoldsForTheSession() {
        prefsFile.writeText(garbage)
        val p = LocalPreferences()
        p.setLanguage("fr")
        p.setBool("showProcessingWindow", false)
        assertEquals("fr", p.language)
        assertEquals(false, p.showProcessingWindow)
    }

    @Test fun aFileWhoseRootIsNotAnObjectIsUnreadableToo() {
        prefsFile.writeText("""["a", "b"]""")
        LocalPreferences().setLanguage("de")
        assertEquals("""["a", "b"]""", prefsFile.readText())
        assertTrue(File(prefsFile.path + ".undecodable").exists())
    }

    /** Nothing in an empty file to protect: a preference is written, as when there is no file. */
    @Test fun anEmptyFileIsNotTreatedAsUnreadable() {
        prefsFile.writeText("")
        LocalPreferences().setLanguage("de")
        assertTrue(prefsFile.readText().contains("\"language\":\"de\""), prefsFile.readText())
        assertTrue(!File(prefsFile.path + ".undecodable").exists())
    }

    @Test fun aWriteLeavesNoTemporaryFileBehind() {
        LocalPreferences().setLanguage("de")
        assertEquals(listOf(".star.userprefs.json"), home.list()!!.toList())
    }
}
