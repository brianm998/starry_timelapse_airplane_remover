package com.star.desktop.ui.app

import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyShortcut
import com.star.desktop.domain.ToolType
import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Render This Frame and the eight tools show the gui's shortcuts (R, 1-8) on the menu, and the tools are listed by their names. Each of those keys
 * is the menu's alone: `handleGlobalKey` has no branch for them, or one press would act twice. `AppViewModel` cannot be built in a unit test, so
 * this reads the menu code and the key handler, as `MenuInEveryWindowTest` reads `Main.kt`.
 */
class MenuShortcutsTest {
    private fun read(path: String) = listOf(File(path), File("../$path")).first { it.isFile }.readText()
    private val menu = read("star-desktop/src/main/kotlin/com/star/desktop/ui/app/StarMenuBar.kt")
    private val keys = read("star-desktop/src/main/kotlin/com/star/desktop/ui/app/KeyHandling.kt")

    @Test fun renderAndToolsShowTheGuisShortcuts() {
        assertEquals(8, ToolType.selectable.size)
        val digits = listOf(Key.One, Key.Two, Key.Three, Key.Four, Key.Five, Key.Six, Key.Seven, Key.Eight)
        for (n in 1..8) assertEquals(digits[n - 1], toolDigitKey(n), "tool $n")

        assertTrue(
            menu.lines().any { it.contains("Item(localized(\"ui.render_this_frame\")") && it.contains("shortcut = KeyShortcut(Key.R)") },
            "Render This Frame carries R",
        )
        assertTrue(
            menu.lines().any { it.contains("Item(t.displayName,") && it.contains("shortcut = KeyShortcut(toolDigitKey(i + 1))") },
            "the tools are listed by name, on 1-8",
        )
        assertFalse(menu.contains("ui.tool_n"), "the \"Tool: X (n)\" label is the old wording")

        // One press, one action: the menu has these keys, so the key handler must not.
        val handler = keys.substringAfter("fun handleGlobalKey")
        assertFalse(Regex("""Key\.R\b""").containsMatchIn(handler), "handleGlobalKey still handles R")
        assertFalse(Regex("""Key\.(One|Two|Three|Four|Five|Six|Seven|Eight)\b|DIGIT_KEYS|forShortcut""").containsMatchIn(handler), "handleGlobalKey still handles the tool digits")
    }

    /** The UI test host has no menu bar, so the runner finds the command a key is the accelerator of itself: same key, same modifiers, and only if enabled. */
    @Test fun test_menu_command_for_shortcut() {
        val keep = MenuEntry.Command("Keep", true, KeyShortcut(Key.Two)) {}
        val multi = MenuEntry.Command("Multi", false, KeyShortcut(Key.Seven)) {}
        val reopen = MenuEntry.Command("Reopen", true, KeyShortcut(Key.R, ctrl = true, shift = true)) {}
        val plain = MenuEntry.Command("No shortcut", true, null) {}
        val menus = listOf(
            MenuSpec("A", 'A', listOf(plain, MenuEntry.Divider, keep)),
            MenuSpec("B", 'B', listOf(MenuEntry.Choice("Choice", true) {}, multi, reopen)),
        )
        fun find(key: Key, ctrl: Boolean = false, meta: Boolean = false, alt: Boolean = false, shift: Boolean = false) =
            menuCommandFor(menus, key, ctrl, meta, alt, shift)

        assertEquals(keep, find(Key.Two))
        assertEquals(reopen, find(Key.R, ctrl = true, shift = true))

        assertNull(find(Key.Seven), "a disabled command's key does nothing")
        assertNull(find(Key.Three), "a key no command has")
        assertNull(find(Key.Two, shift = true), "an extra modifier is a different shortcut")
        assertNull(find(Key.R, ctrl = true), "a missing modifier is a different shortcut")
        assertNull(find(Key.R, meta = true, shift = true), "Meta is not Ctrl")
        assertNull(find(Key.R), "R alone is not Ctrl+Shift+R")
    }
}
