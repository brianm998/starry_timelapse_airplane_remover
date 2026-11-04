package com.star.desktop.ui.windows

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
 * The alignment window says what the gui's does (`gherkin/ui/vectors/alignmentWindow.json`; the gui's `AlignmentWindowTextsTests` reads its own
 * view against the same file): the same empty-state texts in the same states, the same chart labels and the same zoom/pan/click help line.
 */
class AlignmentWindowTextsTest {
    @AfterTest fun reset() = Strings.setOverride(null)

    private fun read(path: String) = listOf(File(path), File("../$path")).first { it.isFile }.readText()

    private val vector = JsonParser.parseString(read("gherkin/ui/vectors/alignmentWindow.json")).asJsonObject
    private val labels = vector.getAsJsonObject("chartLabels")

    private fun label(id: String) = labels[id].asString

    @Test fun theEmptyStatesAreTheVectors() {
        val states = vector.getAsJsonArray("emptyStates").map { it.asJsonObject }
        assertTrue(states.size >= 6, "the vector lost states")
        for (s in states) {
            val got = AlignmentWindowTexts.emptyState(
                hasSequence = s["hasSequence"].asBoolean, fetched = s["fetched"].asBoolean,
                hasData = s["hasData"].asBoolean, processing = s["processing"].asBoolean,
            )
            assertEquals(s.getAsJsonArray("lines").map { it.asString }, got, "state ${s["id"].asString}")
        }
        // The window is built from the state, not from its own keys.
        val view = read("star-desktop/src/main/kotlin/com/star/desktop/ui/windows/AlignmentWindowView.kt")
        assertTrue("AlignmentWindowTexts.emptyState(" in view, "the window does not pick its text from the shared states")
        for (key in states.flatMap { it.getAsJsonArray("lines").map { l -> l.asString } }.toSet()) {
            assertTrue("localized(\"$key\")" !in view, "$key is spelled in the view, not taken from the state")
        }
        // Every line is in the catalogue.
        Strings.setOverride("en")
        for (key in states.flatMap { it.getAsJsonArray("lines").map { l -> l.asString } }.toSet()) assertNotEquals(key, localized(key), "$key is missing from the catalogue")
    }

    @Test fun theChartLabelsAreTheVectors() {
        assertEquals(label("currentFrame"), AlignmentWindowTexts.CURRENT_FRAME)
        assertEquals(label("hoverFrame"), AlignmentWindowTexts.HOVER_FRAME)
        assertEquals(label("keypointSeries"), AlignmentWindowTexts.KEYPOINT_SERIES)
        assertEquals(label("keypointValue"), AlignmentWindowTexts.KEYPOINT_VALUE)
        assertEquals(label("frame"), AlignmentWindowTexts.FRAME)
        assertEquals(label("xAxis"), AlignmentWindowTexts.X_AXIS)
        assertEquals(label("keypointYAxis"), AlignmentWindowTexts.KEYPOINT_Y_AXIS)
        assertEquals(label("starKeypointsTitle"), AlignmentWindowTexts.STAR_KEYPOINTS_TITLE)
        assertEquals(label("earthKeypointsTitle"), AlignmentWindowTexts.EARTH_KEYPOINTS_TITLE)
        assertEquals(vector["help"].asString, AlignmentWindowTexts.HELP)

        val chart = read("star-desktop/src/main/kotlin/com/star/desktop/ui/components/AlignmentChart.kt")
        for (needle in listOf(
            "localized(AlignmentWindowTexts.CURRENT_FRAME)", "localized(AlignmentWindowTexts.HOVER_FRAME)",
            "localized(AlignmentWindowTexts.KEYPOINT_SERIES)", "localized(AlignmentWindowTexts.KEYPOINT_VALUE)",
            "localized(AlignmentWindowTexts.X_AXIS)", "localized(AlignmentWindowTexts.KEYPOINT_Y_AXIS)", "contentDescription",
        )) assertTrue(needle in chart, "AlignmentChart.kt lacks: $needle")

        val view = read("star-desktop/src/main/kotlin/com/star/desktop/ui/windows/AlignmentWindowView.kt")
        for (needle in listOf(
            "localized(AlignmentWindowTexts.HELP)", "ChartTitle(localized(AlignmentWindowTexts.STAR_KEYPOINTS_TITLE))",
            "ChartTitle(localized(AlignmentWindowTexts.EARTH_KEYPOINTS_TITLE))",
        )) assertTrue(needle in view, "AlignmentWindowView.kt lacks: $needle")

        // Both charts can zoom, pan and click, so the help line is true of both; and it is in the catalogue, in German too.
        Strings.setOverride("en")
        val english = localized(AlignmentWindowTexts.HELP)
        assertNotEquals(AlignmentWindowTexts.HELP, english)
        for (id in labels.keySet()) assertNotEquals(label(id), localized(label(id)), "${label(id)} is missing from the catalogue")
        Strings.setOverride("de")
        assertNotEquals(english, localized(AlignmentWindowTexts.HELP), "the help line is English in German")
    }
}
