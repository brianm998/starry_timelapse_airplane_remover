package com.star.desktop.ui.app

import androidx.compose.ui.input.key.Key
import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** M5 of the parity plan: while the sequence plays, the keys that step through it do nothing (the gui hides their buttons). */
class KeyHandlingTest {
    @Test fun theKeysThatStepThroughTheSequenceAreTheTransportOnes() {
        for (key in listOf(Key.DirectionLeft, Key.DirectionRight, Key.B, Key.F, Key.Z, Key.X, Key.Home, Key.MoveEnd)) {
            assertTrue(key in TRANSPORT_KEYS, "$key")
        }
    }

    /** w stops a reverse play and space the play, and the editing keys have nothing to do with the transport. */
    @Test fun theKeysThatStopPlaybackOrEditAreNotAmongThem() {
        for (key in listOf(Key.W, Key.Spacebar, Key.R, Key.D, Key.Tab, Key.One, Key.Eight)) {
            assertFalse(key in TRANSPORT_KEYS, "$key")
        }
    }

    /** M4: under the painter the keys that change frame answer (and ask first once paint has started); nothing else does. */
    @Test fun underThePainterOnlyTheFrameKeysAnswer() {
        for (key in listOf(Key.DirectionLeft, Key.DirectionRight, Key.B, Key.F, Key.Z, Key.X)) {
            assertTrue(key in PAINT_MODE_FRAME_KEYS, "$key")
        }
        for (key in listOf(Key.R, Key.D, Key.Tab, Key.W, Key.One, Key.Home, Key.MoveEnd)) {
            assertFalse(key in PAINT_MODE_FRAME_KEYS, "$key")
        }
    }
}
