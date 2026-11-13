package com.star.desktop.ui.windows

import com.google.gson.JsonParser
import com.star.desktop.ui.components.StarArt
import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/** The waiting robot is drawn exactly when the Alignment window shows empty-state lines, and the trouble and waiting art is in its views. */
class AlignmentEmptyStateArtTest {
    private fun read(path: String) = listOf(File(path), File("../$path")).first { it.isFile }.readText()
    private fun ui(path: String) = read("star-desktop/src/main/kotlin/com/star/desktop/ui/$path")

    @Test fun emptyStateArt() {
        val vector = JsonParser.parseString(read("gherkin/ui/vectors/alignmentWindow.json")).asJsonObject
        val states = vector.getAsJsonArray("emptyStates").map { it.asJsonObject }
        assertTrue(states.size >= 6, "the vector lost states")
        for (s in states) {
            val art = AlignmentWindowTexts.emptyStateArt(
                hasSequence = s["hasSequence"].asBoolean, fetched = s["fetched"].asBoolean,
                hasData = s["hasData"].asBoolean, processing = s["processing"].asBoolean,
            )
            val lines = s.getAsJsonArray("lines")
            assertEquals(if (lines.size() == 0) null else StarArt.ART_WAITING, art, "state ${s["id"].asString}")
        }
        assertTrue("AlignmentWindowTexts.emptyStateArt(" in ui("windows/AlignmentWindowView.kt"))
        assertTrue("WaitingArt(" in ui("windows/BlobProcessingWindowView.kt"))
        assertTrue("ART_WAITING" in ui("components/WaitingArt.kt"))
        val app = ui("app/StarApp.kt")
        assertTrue("ART_OOPS" in app)
        assertTrue("ART_HOLD_ON" in app)
        assertTrue("ART_NEW_RELEASE" in ui("dialogs/NewReleaseDialog.kt"))
    }
}
