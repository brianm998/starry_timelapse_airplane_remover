package com.star.desktop.ui.initial

import com.google.gson.JsonParser
import com.star.desktop.i18n.Strings
import com.star.desktop.i18n.localized
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

    private fun read(path: String) = listOf(File(path), File("../$path")).first { it.isFile }.readText()

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
        Strings.setOverride("en")
        val english = localized(key)
        assertNotEquals(key, english, "$key is missing from the catalogue")
        Strings.setOverride("de")
        assertNotEquals(english, localized(key), "$key is English in German")
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
}
