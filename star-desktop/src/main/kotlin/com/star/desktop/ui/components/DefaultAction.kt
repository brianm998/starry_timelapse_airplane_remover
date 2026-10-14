package com.star.desktop.ui.components

import androidx.compose.foundation.focusable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEvent
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type

/** Whether [event] is Return (or the keypad's Enter) going down: the key that triggers a dialog's default button. */
fun isDefaultActionKey(event: KeyEvent): Boolean =
    event.type == KeyEventType.KeyDown && (event.key == Key.Enter || event.key == Key.NumPadEnter)

/**
 * Make Return trigger [action], as a sheet's default button does on macOS (`.keyboardShortcut(.defaultAction)`), and
 * Esc trigger [onEscape] when there is one (the cancel role).
 * Takes the keyboard focus when it appears, so Return is heard without the user having to click in the dialog first.
 */
@Composable
fun Modifier.defaultAction(action: () -> Unit, onEscape: (() -> Unit)? = null): Modifier {
    val focus = remember { FocusRequester() }
    LaunchedEffect(Unit) { runCatching { focus.requestFocus() } }
    return this
        .focusRequester(focus)
        .focusable()
        .onPreviewKeyEvent {
            when {
                isDefaultActionKey(it) -> { action(); true }
                onEscape != null && it.type == KeyEventType.KeyDown && it.key == Key.Escape -> { onEscape(); true }
                else -> false
            }
        }
}
