package com.star.desktop.ui.app

import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * M9 of the parity plan: the menu bar, and the shortcuts on it, were the main window's alone, so with the outlier table, the alignment window,
 * the blob window or the debug window focused there was no menu. macOS has one menu bar for the app; here each window carries the same one.
 * Compose has no test host for windows (§6.3), so this reads `Main.kt`.
 */
class MenuInEveryWindowTest {
    @Test fun everyWindowHasTheMenu() {
        val source = listOf(File("src/main/kotlin/com/star/desktop/Main.kt"), File("star-desktop/src/main/kotlin/com/star/desktop/Main.kt")).first { it.isFile }.readText()
        val windows = Regex("""(?m)^\s*Window\(""").findAll(source).count()
        assertTrue(windows >= 5, "the main window and the four others")
        assertEquals(windows, Regex("""StarMenuBar\(vm\)""").findAll(source).count(), "a window without the menu bar: its shortcuts do nothing")
    }
}
