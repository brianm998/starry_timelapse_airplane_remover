package com.star.desktop.ui.dialogs

import com.google.gson.JsonParser
import java.io.File
import kotlin.test.Test
import kotlin.test.assertTrue

/**
 * The multi-frame sheets have the gui's titles and layout (`gherkin/ui/vectors/multiSheets.json`; the gui's `MultiSheetLayoutTests` reads its own sheets
 * against the same file): the action is one segmented row (the gui's `.segmented` picker), the range a list of radio rows (its `.inline` picker), and the
 * count of a next/previous range sits inline, "the next [N] frames", where the gui has it. The sheets used to be titled by the desktop's own keys, show
 * coloured pills, and ask for the count in a separate "Number of frames" field.
 */
class MultiSheetLayoutTest {
    private fun read(path: String) = listOf(File(path), File("../$path")).first { it.isFile }.readText()

    private val vector = JsonParser.parseString(read("gherkin/ui/vectors/multiSheets.json")).asJsonObject
    private val source = read("star-desktop/src/main/kotlin/com/star/desktop/ui/dialogs/MultiFrameSheets.kt")

    @Test fun theTitlesAreTheGuis() {
        for (name in listOf("overlapTitle", "areaTitle")) {
            val key = vector[name].asString
            assertTrue("title = localized(\"$key\")" in source, "$name: the sheet is not titled $key")
        }
        for (old in listOf("ui.change_overlapping_outliers_in_other_frames", "ui.change_outliers_in_the_selected_area_across")) {
            assertTrue(old !in source, "the desktop's own title $old is still on a sheet")
        }
    }

    @Test fun theCountIsInlineAndTheChoicesAreTheGuis() {
        assertTrue("Pill(" !in source, "the action is still a row of coloured pills")
        assertTrue("SegmentedRow(" in source, "the action is not a segmented row")
        assertTrue("RadioRow(r.label" in source, "the range is not a list of radio rows")
        assertTrue("ui.number_of_frames" !in source, "the count still has its own labelled field")
        val lead = vector.getAsJsonArray("countLead").map { it.asString }
        for (key in lead) assertTrue("\"$key\"" in source, "the inline count lacks its lead $key")
        val positions = listOf("\"${lead[0]}\"", "CountField(", "localized(\"${vector["countTrail"].asString}\")")
            .map { n -> source.indexOf(n).also { assertTrue(it >= 0, "the inline count lacks: $n") } }
        assertTrue(positions == positions.sorted(), "the inline count is not 'the next [N] frames' in order")
    }

    @Test fun theTrashSwitchStaysInTheAreaSheet() {
        assertTrue("localized(\"${vector["trashLabel"].asString}\")" in source)
        assertTrue("trashInitially = vm.showTrash.value" in source)
    }
}
