package com.star.desktop.ui.app

import com.google.gson.JsonObject
import com.google.gson.JsonParser
import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals

/**
 * Layer 0 of the parity plan (§6.2.1): `gherkin/ui/ids.json` lists the identifiers a UI step may use. This scans the `Modifier.testTag("...")`
 * calls under `star-desktop/src/main` (a template such as `"videoimport.format.${choice}"` counts as the family `videoimport.format.*`) and
 * checks them against it; the gui's `IdRegistryTests` scans `.accessibilityIdentifier("...")` against the same file.
 */
class IdRegistryTest {
    private fun repoDir(relative: String): File = listOf(File("../$relative"), File(relative)).first { it.exists() }

    private val registry: JsonObject = JsonParser.parseString(repoDir("gherkin/ui/ids.json").readText()).asJsonObject
    private val ids: List<String> = registry.getAsJsonArray("ids").map { it.asString }
    private val gaps = registry.getAsJsonObject("knownGaps")
    private val desktopGaps: Set<String> = gaps.getAsJsonObject("desktop").keySet()
    private val guiGaps: Set<String> = gaps.getAsJsonObject("gui").keySet()

    private val found: Set<String> = run {
        val pattern = Regex("""testTag\("([^"]+)"\)""")
        repoDir("star-desktop/src/main").walkTopDown().filter { it.isFile && it.extension == "kt" }
            .flatMap { pattern.findAll(it.readText()).map { m -> m.groupValues[1].replace(Regex("""\$\{[^}]*}"""), "*") } }
            .toSet()
    }

    /** An entry covers an id when they are equal or the entry is a `prefix*` family the id falls in. */
    private fun covers(entry: String, id: String) = if (entry.endsWith("*")) id.startsWith(entry.dropLast(1)) else entry == id

    @Test fun everyIdBothClientsCarryIsHere() {
        val missing = ids.filter { entry -> found.none { covers(entry, it) } }
        assertEquals(emptyList(), missing, "ids the gui has and this client lacks: add them, or list them in knownGaps.desktop")
    }

    @Test fun everyIdThisClientCarriesIsRegistered() {
        val known = ids + desktopGaps + guiGaps
        val unregistered = found.filter { id -> known.none { covers(it, id) } }.sorted()
        assertEquals(emptyList(), unregistered, "ids this client carries that gherkin/ui/ids.json does not list")
    }

    @Test fun aGapThisClientHasClosedIsRemoved() {
        assertEquals(emptyList(), desktopGaps.filter { gap -> found.any { covers(gap, it) } }.sorted(), "knownGaps.desktop entries this client now has")
        assertEquals(emptyList(), guiGaps.filter { gap -> found.none { covers(gap, it) } }.sorted(),
            "knownGaps.gui entries this client does not have either: they are not gaps of the gui's alone")
    }
}
