package com.star.desktop.ui.app

import com.star.desktop.applyMacDarkAppearance
import kotlin.test.Test
import kotlin.test.assertEquals

/** The AWT dialogs on macOS follow the dark appearance only when the JVM is told so, and only on macOS. */
class MacDarkAppearanceTest {
    private fun set(os: String): Map<String, String> {
        val props = mutableMapOf<String, String>()
        applyMacDarkAppearance(os) { k, v -> props[k] = v }
        return props
    }

    @Test fun macSetsTheDarkAwtAppearance() {
        assertEquals(
            mapOf("apple.awt.application.appearance" to "NSAppearanceNameDarkAqua"),
            set("Mac OS X"),
        )
    }

    @Test fun windowsLeavesTheAppearanceAlone() {
        assertEquals(emptyMap(), set("Windows 11"))
    }

    @Test fun linuxLeavesTheAppearanceAlone() {
        assertEquals(emptyMap(), set("Linux"))
    }
}
