package com.star.desktop.ui.app

import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyShortcut
import kotlin.test.Test
import kotlin.test.assertEquals

class WindowShortcutTest {
    /** On a Mac: Option plus the letter, as the Mac app has it. */
    @Test fun onMacItIsOptionAndTheLetter() {
        assertEquals(KeyShortcut(Key.O, alt = true), windowShortcut(Key.O, isMac = true))
        assertEquals(KeyShortcut(Key.A, alt = true), windowShortcut(Key.A, isMac = true))
    }

    /** Elsewhere a plain Alt+letter would open a menu by its mnemonic, so Ctrl comes with it. */
    @Test fun elsewhereItIsCtrlAltAndTheLetter() {
        assertEquals(KeyShortcut(Key.O, ctrl = true, alt = true), windowShortcut(Key.O, isMac = false))
    }
}
