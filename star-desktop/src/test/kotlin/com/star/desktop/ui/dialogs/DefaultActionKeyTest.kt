package com.star.desktop.ui.dialogs

import androidx.compose.ui.InternalComposeUiApi
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEvent
import androidx.compose.ui.input.key.KeyEventType
import com.star.desktop.ui.components.isDefaultActionKey
import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** Return is a sheet's default button on macOS; it has to be on every dialog of this client that has one. */
@OptIn(InternalComposeUiApi::class)
class DefaultActionKeyTest {
    @Test fun returnAndKeypadEnterGoingDownTriggerTheDefaultAction() {
        assertTrue(isDefaultActionKey(KeyEvent(Key.Enter, KeyEventType.KeyDown)))
        assertTrue(isDefaultActionKey(KeyEvent(Key.NumPadEnter, KeyEventType.KeyDown)))
    }

    /** Once per press: the release must not trigger it again (the dialog would already be gone, or the next one would fire). */
    @Test fun theReleaseDoesNot() {
        assertFalse(isDefaultActionKey(KeyEvent(Key.Enter, KeyEventType.KeyUp)))
    }

    @Test fun otherKeysDoNot() {
        assertFalse(isDefaultActionKey(KeyEvent(Key.Spacebar, KeyEventType.KeyDown)))
        assertFalse(isDefaultActionKey(KeyEvent(Key.Escape, KeyEventType.KeyDown)))
    }
}
