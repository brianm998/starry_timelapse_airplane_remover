package com.star.desktop.ui.app

import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEvent
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.isAltPressed
import androidx.compose.ui.input.key.isCtrlPressed
import androidx.compose.ui.input.key.isMetaPressed
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.type
import com.star.desktop.domain.ToolType

/**
 * Global key handling, wired to the window's `onKeyEvent` (the **bubble** phase, so a focused text
 * field — e.g. the editable frame number — consumes its keys first and is never starved; this was a
 * v1 bug where `onPreviewKeyEvent` returned true globally and ate keystrokes meant for fields).
 *
 * Modes/process/outlier shortcuts live on the menu bar (E/S/G, A/K/U, ⌘O/⌘W/⌘,). Here we add the
 * navigation + tool shortcuts that aren't menu-driven: arrows for frame nav, digits 1–8 for tools
 * (in every mode).
 */
fun handleGlobalKey(event: KeyEvent, app: AppViewModel): Boolean {
    if (event.type != KeyEventType.KeyDown) return false
    val svm = (app.screen.value as? AppScreen.Sequence)?.vm ?: return false
    // While the horizon painter is open its own keys (brush size, sky/ground, reset, return, escape) are the ones that
    // count; r would otherwise render the frame under it, and the arrows move off the frame being painted.
    if (svm.horizonPaintMode.value) return false
    // Under the processing screen nothing behind it should answer to a key, nor under the panel that reports on a reopened sequence
    // (the gui's `isProcessingModalUp` covers both; this one used to let the arrows and r through it).
    if (svm.showProcessingModal.value || app.sequenceProgress.value != null) return false
    // While the sequence plays the buttons that move through it are gone in the gui, and their keys with them: only the ones that
    // stop it (w, and space on the menu) still answer.
    if (svm.isPlaying.value && event.key in TRANSPORT_KEYS) return false
    // Ctrl, Cmd and Alt with a letter are the menu's (Ctrl+R would render the frame, Ctrl+Z skip back), not the plain keys that move and edit.
    if (event.isCtrlPressed || event.isMetaPressed || event.isAltPressed) return false

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
        // Decision Tree All on the current frame (macOS ApplyAllDecisionTreeButton's `d`).
        // In any mode, as the gui does (it was edit mode only here): the decisions are the frame's, whatever is on screen.
        Key.D -> {
            if (!svm.currentFrameUsesOutliers()) return false
            svm.applyDecisionTreeToCurrentFrame()
            return true
        }
    }

    // The tools are on 1-8 in every mode (macOS), so the choice is there when the user gets back to the frame; a frame whose method has
    // no use for them (setTool) leaves the tool alone.
    val digit = DIGIT_KEYS[event.key]
    if (digit != null) {
        ToolType.forShortcut(digit)?.let { svm.setTool(it) }
        return true
    }
    return false
}

/** The keys that step through the sequence (the macOS `VideoPlaybackButtons` shortcuts, and Home and End). */
internal val TRANSPORT_KEYS: Set<Key> = setOf(
    Key.DirectionLeft, Key.DirectionRight, Key.Home, Key.MoveEnd, Key.B, Key.F, Key.Z, Key.X,
)

private val DIGIT_KEYS: Map<Key, Int> = mapOf(
    Key.One to 1, Key.Two to 2, Key.Three to 3, Key.Four to 4,
    Key.Five to 5, Key.Six to 6, Key.Seven to 7, Key.Eight to 8,
)
