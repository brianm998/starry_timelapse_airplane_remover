package com.star.desktop.ui.initial

import com.google.gson.JsonParser
import com.star.desktop.engine.EngineStatus
import com.star.desktop.i18n.Strings
import com.star.desktop.i18n.localized
import com.star.desktop.util.BuildInfo
import com.star.desktop.util.headingVersion
import java.io.File
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotEquals
import kotlin.test.assertTrue

/**
 * S8: the start screen's controls say what the gui's do, in its order, with its hover texts (`gherkin/ui/vectors/startScreen.json`; the gui's
 * `StartScreenTests` reads its own view against the same file). The labels were "About Star", "Open Image Sequence…", "Open Video…", "Resume…".
 */
class StartScreenTest {
    @AfterTest fun reset() = Strings.setOverride(null)

    private fun read(path: String) = listOf(File(path), File("../$path")).first { it.isFile }.readText().replace("\r\n", "\n") // a Windows checkout has CRLF, and the needles below span lines

    private val controls = JsonParser.parseString(read("gherkin/ui/vectors/startScreen.json")).asJsonObject.getAsJsonArray("controls").map { it.asJsonObject }

    @Test fun theLabelsAreTheVectorsInOrder() {
        val source = read("star-desktop/src/main/kotlin/com/star/desktop/ui/initial/InitialView.kt")
        val positions = controls.map { c -> source.indexOf("localized(\"${c["label"].asString}\")").also { assertTrue(it >= 0, "${c["label"]} is not on the start screen") } }
        assertEquals(positions.sorted(), positions, "the controls are not in the gui's order")
    }

    @Test fun everyControlHasItsHoverText() {
        val source = read("star-desktop/src/main/kotlin/com/star/desktop/ui/initial/InitialView.kt")
        for (c in controls) assertTrue("HoverTip(localized(\"${c["tip"].asString}\"))" in source, "${c["id"]} has no hover text")
    }

    @Test fun aRecentCanBeRemovedAndSaysSo() {
        val source = read("star-desktop/src/main/kotlin/com/star/desktop/ui/initial/InitialView.kt")
        val key = JsonParser.parseString(read("gherkin/ui/vectors/startScreen.json")).asJsonObject["removeRecent"].asString
        assertTrue("HoverTip(localized(\"$key\"))" in source, "the remove button has no hover text")
        assertTrue("testTag(\"startup.recent.open\")" in source && "testTag(\"startup.recent.remove\")" in source, "a row lacks its ids")
        Strings.setOverride("en")
        val english = localized(key)
        assertNotEquals(key, english, "$key is missing from the catalogue")
        Strings.setOverride("de")
        assertNotEquals(english, localized(key), "$key is English in German")
    }

    /** The zone says what the gui's does (its key, a document icon, a dashed border that goes accent under a drag) and is clickable, with a hover text. */
    @Test fun theDropZoneSaysWhatTheGuisSays() {
        val source = read("star-desktop/src/main/kotlin/com/star/desktop/ui/initial/InitialView.kt")
        for (needle in listOf(
            "localized(\"ui.drop_a_video_an_image_sequence_or_an\")", "DropZoneIcon()", "dashPathEffect", "if (isHovering) StarColors.accent else Color.White",
            "HoverTip(localized(\"ui.load_an_image_sequence_yet_to_be_processed\")) {\n                            DropZone(", ".clickable(onClick = onOpenSequence)",
            "testTag(\"startup.dropzone\")",
        )) assertTrue(needle in source, "InitialView.kt lacks: $needle")
        assertTrue("ui.drop_an_image_sequence_folder_video_or" !in source, "the desktop's own drop zone text is still on the start screen")
    }

    @Test fun theyAreTranslated() {
        Strings.setOverride("en")
        val english = controls.flatMap { listOf(it["label"].asString, it["tip"].asString) }.associateWith { localized(it) }
        for ((key, text) in english) assertNotEquals(key, text, "$key is missing from the catalogue")
        Strings.setOverride("de")
        for (key in controls.flatMap { listOf(it["label"].asString, it["tip"].asString) }) {
            if (key == "ui.load_config") continue   // "Load Config" is what German says too
            assertNotEquals(english[key], localized(key), "$key is English in German")
        }
    }

    /** A4: the heading is there from the first frame, with this build's own version, as the gui's is; the engine's replaces it once it reports. */
    @Test fun theHeadingDoesNotWaitForTheEngine() {
        val source = read("star-desktop/src/main/kotlin/com/star/desktop/ui/initial/InitialView.kt")
        assertTrue("(engineStatus as? EngineStatus.Connected)" !in source, "the heading still waits for Connected")
        val config = read("StarCore/Sources/StarCore/Config.swift")
        val latest = Regex("""static let latestVersion\s*=\s*"([^"]+)"""").find(config)!!.groupValues[1]
        assertEquals(latest, BuildInfo.version, "the build did not stamp Config.latestVersion into the client")
        Strings.setOverride("en")
        for (status in listOf(EngineStatus.Disconnected, EngineStatus.Connecting)) {
            val heading = localized("ui.welcome_to_star", headingVersion(status))
            assertTrue(latest in heading, "the heading before the engine connects is \"$heading\"")
        }
        assertEquals("9.9.9", headingVersion(EngineStatus.Connected("9.9.9", "/tmp")), "the engine's version wins once it has connected")
    }

    /** A3: the gui's sizes and one clear button style: no accent-filled button on the start screen. */
    @Test fun theButtonsAreOneStyleAtTheGuisSize() {
        val source = read("star-desktop/src/main/kotlin/com/star/desktop/ui/initial/InitialView.kt")
        for (key in listOf("ui.learn_about_star", "ui.load_video", "ui.load_image_sequence", "ui.load_config"))
            assertTrue("Text(localized(\"$key\"), style = StarType.largeTitle)" in source, "$key is not at largeTitle")
        assertTrue("ButtonDefaults" !in source && "containerColor" !in source, "a button is accent-filled")
    }
}
