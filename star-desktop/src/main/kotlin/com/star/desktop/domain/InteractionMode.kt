package com.star.desktop.domain

/**
 * The three top-level interaction modes (macOS `ContentView`/`ViewModel.InteractionMode`).
 * Shortcuts: edit=E, scrub=S, grid=G. The macOS app defaults to [SCRUB].
 */
enum class InteractionMode(val labelKey: String, val shortcutChar: Char) {
    EDIT("interaction_mode.edit", 'e'),
    SCRUB("interaction_mode.scrub", 's'),
    GRID("interaction_mode.grid", 'g'),
}
