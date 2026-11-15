package com.star.desktop.domain

import com.google.gson.JsonObject
import com.google.gson.JsonParser
import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals

/**
 * Layer 0 of the parity plan (§6.2.4): the outlier table's columns are the ones `gherkin/ui/vectors/outlierColumns.json` lists, in the same
 * order, named with the same catalogue keys and shown at first by the same defaults. The gui's `OutlierColumnsTests` checks its own table
 * against the same file.
 */
class OutlierColumnsTest {
    private val doc: JsonObject = JsonParser.parseString(
        listOf(File("../gherkin/ui/vectors/outlierColumns.json"), File("gherkin/ui/vectors/outlierColumns.json")).first { it.isFile }.readText(),
    ).asJsonObject

    @Test fun theColumnsAlwaysShownAreTheVectors() {
        val fixed = doc.getAsJsonArray("fixed").map { it.asJsonObject }
        assertEquals(listOf(OutlierTable.DECISION, OutlierTable.SIZE), fixed.map { it["key"].asString })
        // the table's headers: `localized("ui.remove")` and `localized("ui.size")`
        assertEquals(listOf("ui.remove", "ui.size"), fixed.map { it["label"].asString })
    }

    @Test fun theOptionalColumnsAreTheVectorsInOrderWithItsNamesAndDefaults() {
        val optional = doc.getAsJsonArray("optional").map { it.asJsonObject }
        assertEquals(optional.map { it["key"].asString }, OutlierTable.columns.map { it.key })
        assertEquals(optional.map { it["label"].asString }, OutlierTable.columns.map { it.labelKey })
        assertEquals(optional.map { it["default"].asBoolean }, OutlierTable.columns.map { it.defaultVisible })
    }
}
