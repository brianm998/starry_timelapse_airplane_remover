package com.star.desktop.ui.app

import com.google.gson.JsonObject
import com.google.gson.JsonParser
import androidx.compose.ui.input.key.Key
import com.star.desktop.domain.ToolType
import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
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

    /** The menu bar's code cut at each `Menu(localized("<title key>")`: the title key and the text of that menu. */
    private fun menuBlocks(): Map<String, String> {
        val starts = Regex("""Menu\(localized\("([^"]+)"\)""").findAll(menu).toList()
        return starts.mapIndexed { i, m -> m.groupValues[1] to menu.substring(m.range.last, starts.getOrNull(i + 1)?.range?.first ?: menu.length) }.toMap()
    }

    /** M12 / D9: each command is in the menu the table says (the gui's tree: File, Actions, Tools, Window), and in no other. */
    @Test fun everyCommandIsInItsMenuAndNoOther() {
        val blocks = menuBlocks()
        val titles = table.getAsJsonObject("menus").entrySet().associate { it.key to it.value.asString }
        val wrong = table.getAsJsonArray("commands").map { it.asJsonObject }
            .filter { it["id"].asString !in gaps }
            .mapNotNull { c ->
                val label = "\"${c["label"].asString}\""
                val inMenus = blocks.filterValues { it.contains(label) }.keys
                val expected = titles.getValue(c["menu"].asString)
                if (inMenus == setOf(expected)) null else "${c["id"].asString}: in $inMenus, expected $expected"
            }
        assertTrue(wrong.isEmpty(), "commands in the wrong menu: $wrong")
    }

    @Test fun theMenusAreTheGuisAndTheLanguageMenu() {
        val titles = menuBlocks().keys.toList()
        assertTrue(titles == listOf("ui.file", "menu.actions", "menu.tools", "ui.window", "language.menu"), "menus: $titles")
    }

    /** How this client's menu code spells the table's `shortcut` (`r`, `cmd+shift+,`, `option+p`, `space`). */
    private fun spelled(shortcut: String): String {
        val parts = shortcut.split("+")
        val k = parts.last()
        val key = when (k) { "," -> "Key.Comma"; "space" -> "Key.Spacebar"; else -> "Key.${k.uppercase()}" }
        val mods = parts.dropLast(1)
        return when (mods) {
            emptyList<String>() -> "KeyShortcut($key)"
            listOf("cmd") -> "primaryShortcut($key)"
            listOf("cmd", "shift") -> "primaryShortcut($key, shift = true)"
            listOf("option") -> "windowShortcut($key, IS_MAC)"
            else -> error("a shortcut this test cannot spell: $shortcut")
        }
    }

    /** The menu code's line for the command: the `Item(` that names its label key. */
    private fun itemLine(label: String): String = menu.lines().first { it.contains("\"$label\"") && it.contains("Item(") }

    /** The shortcut of every command is the table's (the gui's), and a command the table gives none has none; the Tools menu's first eight items are the tools' names on 1-8. */
    @Test fun theShortcutsAreTheVectors() {
        val wrong = table.getAsJsonArray("commands").map { it.asJsonObject }
            .filter { it["id"].asString !in gaps }
            .mapNotNull { c ->
                val line = itemLine(c["label"].asString)
                val expected = c["shortcut"]?.asString
                val has = line.contains("shortcut = ")
                when {
                    expected == null && has -> "${c["id"].asString}: has a shortcut the table does not"
                    expected != null && !line.contains("shortcut = ${spelled(expected)}") -> "${c["id"].asString}: expected ${spelled(expected)} in: ${line.trim()}"
                    else -> null
                }
            }
        assertTrue(wrong.isEmpty(), "shortcuts that are not the table's: $wrong")

        val tools = table.getAsJsonArray("toolShortcuts").map { it.asJsonObject }
        assertEquals(
            ToolType.selectable.map { it.name.replace("_", "").lowercase() },
            tools.map { it["tool"].asString.lowercase() },
            "the table's tools, in order, are the ones the desktop binds to the number keys",
        )
        assertEquals((1..8).map { it.toString() }, tools.map { it["shortcut"].asString }, "tools are on 1-8 in order")
        val digits = listOf(Key.One, Key.Two, Key.Three, Key.Four, Key.Five, Key.Six, Key.Seven, Key.Eight)
        for ((i, t) in tools.withIndex()) {
            assertEquals(digits[t["shortcut"].asString.toInt() - 1], toolDigitKey(i + 1), "tool ${t["tool"].asString}")
        }
        val toolsLine = menu.lines().first { it.contains("ToolType.selectable.forEachIndexed") }
        val loop = menu.lines().dropWhile { it != toolsLine }.drop(1).take(3).joinToString("\n")
        assertTrue(loop.contains("Item(t.displayName,") && loop.contains("shortcut = KeyShortcut(toolDigitKey(i + 1))"), "the Tools items: $loop")
    }
}
