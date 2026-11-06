package com.star.desktop.domain

import com.star.desktop.i18n.localized

/** How the last run ended, kept until the user next opens the menu or starts a run (macOS `RunOutcome`). */
enum class RunOutcome { FINISHED, FAILED }

/** The latched outcome of the last run (macOS `MenuBarOutcome`). Cancelling sets nothing: a cancelled run just goes idle. */
data class MenuBarOutcome(val outcome: RunOutcome? = null) {
    fun runStarted() = MenuBarOutcome(null)
    fun runEnded(outcome: RunOutcome) = MenuBarOutcome(outcome)
    fun menuOpened() = MenuBarOutcome(null)
}

/** The four looks of the tray icon; [id] is the same id the macOS wand uses. */
enum class MenuBarIcon(val id: String) {
    IDLE("idle"), RUNNING("running"), FINISHED("finished"), FAILED("failed");

    companion object {
        /** A run in progress wins over a stale outcome; then the outcome; then idle. */
        fun of(status: MenuBarStatus, outcome: RunOutcome?): MenuBarIcon = when {
            status != MenuBarStatus.Idle -> RUNNING
            outcome == RunOutcome.FINISHED -> FINISHED
            outcome == RunOutcome.FAILED -> FAILED
            else -> IDLE
        }
    }
}

/** The ring's fill, 0 to 1 in 5% steps, so the icon is redrawn only when that changes. */
val MenuBarStatus.ringStep: Int
    get() = when (this) {
        MenuBarStatus.Idle -> 0
        is MenuBarStatus.Processing -> (fraction.coerceIn(0f, 1f) * 20).toInt()
        is MenuBarStatus.Rendering -> (fraction.coerceIn(0f, 1f) * 20).toInt()
    }

/** The tray's tooltip: names the state. */
fun MenuBarStatus.tooltip(outcome: RunOutcome?): String = when (this) {
    MenuBarStatus.Idle -> when (outcome) {
        RunOutcome.FINISHED -> localized("ui.menu_bar.tooltip.finished")
        RunOutcome.FAILED -> localized("ui.menu_bar.tooltip.failed")
        null -> localized("ui.menu_bar.tooltip.idle")
    }
    is MenuBarStatus.Processing -> localized("ui.menu_bar.tooltip.processing", (fraction * 100).toInt())
    is MenuBarStatus.Rendering -> localized("ui.menu_bar.tooltip.rendering", (fraction * 100).toInt())
}
