package com.star.desktop.ui.app

import com.google.gson.JsonObject
import com.google.gson.JsonParser
import java.io.File
import kotlin.test.Test
import kotlin.test.assertTrue

/**
 * Layer 0 of the parity plan: `gherkin/ui/commands.json` lists the menu commands both clients offer, by the catalogue key of the
 * label. This client's menu code has to use every one (a command added to the other client only is a failure here), and a known gap
 * has to still be a gap.
 */
class CommandTableTest {
    private fun repoFile(relative: String): File =
        listOf(File("../$relative"), File(relative)).first { it.isFile }

    private val table: JsonObject = JsonParser.parseString(repoFile("gherkin/ui/commands.json").readText()).asJsonObject
    private val menu: String = repoFile("star-desktop/src/main/kotlin/com/star/desktop/ui/app/StarMenuBar.kt").readText()
    private val english: JsonObject = JsonParser.parseString(repoFile("StarCore/Sources/StarCore/Resources/Localizations/en.json").readText()).asJsonObject

    private val gaps: Set<String> = table.getAsJsonObject("knownGaps").getAsJsonObject("desktop").keySet()

    private fun uses(key: String) = menu.contains("\"$key\"")

    @Test fun everyCommandIsInThisClientsMenuOrIsAKnownGap() {
        val missing = table.getAsJsonArray("commands")
            .map { it.asJsonObject }
            .filter { !uses(it["label"].asString) && it["id"].asString !in gaps }
            .map { "${it["id"].asString} (${it["label"].asString})" }
        assertTrue(missing.isEmpty(), "menu commands the gui has and this client's menu lacks: $missing")
    }

    @Test fun aKnownGapIsStillAGap() {
        val stale = table.getAsJsonArray("commands").map { it.asJsonObject }
            .filter { it["id"].asString in gaps && uses(it["label"].asString) }
            .map { it["id"].asString }
        assertTrue(stale.isEmpty(), "known gaps that are closed, to be removed from commands.json: $stale")
    }

    @Test fun everyLabelIsInTheCatalogue() {
        val unknown = table.getAsJsonArray("commands").map { it.asJsonObject["label"].asString }.filter { !english.has(it) }
        assertTrue(unknown.isEmpty(), "labels that are not catalogue keys: $unknown")
    }
}
