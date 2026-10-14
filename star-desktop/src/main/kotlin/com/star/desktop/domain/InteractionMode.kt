package com.star.desktop.domain

/**
 * The three top-level interaction modes (macOS `ContentView`/`ViewModel.InteractionMode`).
 * Shortcuts: edit=E, scrub=S, grid=G. The macOS app defaults to [SCRUB].
 */
enum class InteractionMode(val labelKey: String, val shortcutChar: Char) {
    EDIT("interaction_mode.edit", 'e'),
    SCRUB("interaction_mode.scrub", 's'),
    GRID("interaction_mode.grid", 'g');

    companion object {
        /** The mode a sequence opens in (macOS): edit for a source opened for the first time, scrub for one resumed from its config. */
        fun onOpening(freshSource: Boolean): InteractionMode = if (freshSource) EDIT else SCRUB
    }
}
