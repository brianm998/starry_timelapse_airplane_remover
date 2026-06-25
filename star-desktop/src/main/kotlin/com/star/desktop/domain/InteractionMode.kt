package com.star.desktop.domain

/**
 * The three top-level interaction modes (macOS `ContentView`/`ViewModel.InteractionMode`).
 * Shortcuts: edit=E, scrub=S, grid=G. The macOS app defaults to [SCRUB].
 */
enum class InteractionMode(val displayName: String, val shortcutChar: Char) {
    EDIT("Edit", 'e'),
    SCRUB("Scrub", 's'),
    GRID("Grid", 'g'),
}
