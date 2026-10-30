package com.star.desktop.ui.components

import androidx.compose.foundation.clickable
import androidx.compose.foundation.focusable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.platform.LocalFocusManager
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

/**
 * The scrim behind a dialog: it swallows clicks instead of closing the dialog on one. Every dialog is modal in both clients (a sheet on macOS
 * is), and ends with one of its own buttons, Return for the default one, or Esc for the cancel role ([defaultAction]); a stray click that
 * lost the user their choices was the desktop's alone.
 */
@Composable
fun Modifier.modalScrim(): Modifier =
    this.clickable(interactionSource = remember { MutableInteractionSource() }, indication = null) {}

/**
 * One rule for every number field, the macOS `EditableNumberView`'s: Return commits what was typed, Esc puts the old value back, and either gives
 * the keyboard back to the frame (a field that kept it swallowed the digits and arrows meant for the view); leaving the field commits too.
 * [commit] must treat a value that is not valid, or is the one already in force, as nothing to do. (Q9 of the parity plan.)
 */
@Composable
fun Modifier.numberFieldRules(commit: () -> Unit, revert: () -> Unit): Modifier {
    val focus = LocalFocusManager.current
    var hadFocus by remember { mutableStateOf(false) }
    // The focus Esc gives up must not read as "left the field" and commit the text that was just thrown away.
    var reverting by remember { mutableStateOf(false) }
    return this
        .onPreviewKeyEvent { e ->
            when {
                isDefaultActionKey(e) -> { commit(); focus.clearFocus(); true }
                e.type == KeyEventType.KeyDown && e.key == Key.Escape -> { reverting = true; revert(); focus.clearFocus(); true }
                else -> false
            }
        }
        .onFocusChanged {
            if (it.isFocused) {
                hadFocus = true
            } else if (hadFocus) {
                hadFocus = false
                if (reverting) reverting = false else commit()
            }
        }
}
