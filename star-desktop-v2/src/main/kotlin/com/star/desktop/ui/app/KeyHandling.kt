package com.star.desktop.ui.app

import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEvent
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.type
import com.star.desktop.domain.InteractionMode
import com.star.desktop.domain.ToolType

/**
 * Global key handling, wired to the window's `onKeyEvent` (the **bubble** phase, so a focused text
 * field — e.g. the editable frame number — consumes its keys first and is never starved; this was a
 * v1 bug where `onPreviewKeyEvent` returned true globally and ate keystrokes meant for fields).
 *
 * Modes/process/outlier shortcuts live on the menu bar (E/S/G, A/K/U, ⌘O/⌘W/⌘,). Here we add the
 * navigation + tool shortcuts that aren't menu-driven: arrows for frame nav, digits 1–8 for tools
 * (edit mode only).
 */
fun handleGlobalKey(event: KeyEvent, app: AppViewModel): Boolean {
    if (event.type != KeyEventType.KeyDown) return false
    val svm = (app.screen.value as? AppScreen.Sequence)?.vm ?: return false

    when (event.key) {
        Key.DirectionLeft -> { svm.previous(); return true }
        Key.DirectionRight -> { svm.next(); return true }
        Key.Home -> { svm.setCurrentIndex(0); return true }
        Key.MoveEnd -> { svm.setCurrentIndex(svm.frameCount - 1); return true }
        // Transport letter keys (macOS VideoPlaybackButtons): b/f ends, z/x fast-skip, w reverse-play.
        Key.B -> { svm.goToFirst(); return true }
        Key.F -> { svm.goToLast(); return true }
        Key.Z -> { svm.fastPrevious(); return true }
        Key.X -> { svm.fastForward(); return true }
        Key.W -> { svm.playReverse(); return true }
        // Editing accelerators. r renders the current frame; Tab toggles the side panels (macOS
        // TabCatcher). h (toggle horizon painter) lives on the menu bar so it isn't double-handled.
        Key.R -> { svm.renderCurrentFrame(); return true }
        Key.Tab -> { svm.toggleSidePanels(); return true }
    }

    val digit = DIGIT_KEYS[event.key]
    if (digit != null && svm.mode.value == InteractionMode.EDIT) {
        ToolType.forShortcut(digit)?.let { svm.setTool(it) }
        return true
    }
    return false
}

private val DIGIT_KEYS: Map<Key, Int> = mapOf(
    Key.One to 1, Key.Two to 2, Key.Three to 3, Key.Four to 4,
    Key.Five to 5, Key.Six to 6, Key.Seven to 7, Key.Eight to 8,
)
