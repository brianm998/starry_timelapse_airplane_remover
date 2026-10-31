package com.star.desktop.ui.app

import kotlin.test.Test
import kotlin.test.assertEquals

/**
 * M12 / D9 of the parity plan: which menu items are on in which state is the gui's (`StarCommands.swift`): the single-key commands
 * (`menuHotkeysEnabled`) are off under the processing screen and while the horizon painter is open, Process Current Frame, Processing Settings
 * and the painter's own item only under the processing screen (`!isProcessingModalUp`), Cancel Processing only while a run is going, Render Video
 * not while a video is rendering. The `@ui` features `uiMenuCommandsIdle` and `uiMenuCommandsWhilePainting` hold both clients to the idle and the painting
 * states in the real apps; the states a feature cannot reach without a run (the processing screen up, a run going, a video rendering) are here.
 */
class MenuStateTest {
    private fun rules(s: MenuState) = listOf(s.hotkeys, s.notUnderModal, s.canCancel, s.canRenderVideo)

    @Test fun withoutASequenceNothingIsOn() {
        assertEquals(listOf(false, false, false, false), rules(MenuState(hasSession = false)))
        // even a run or a render that a closing sequence has left behind
        assertEquals(listOf(false, false, false, false), rules(MenuState(hasSession = false, processing = true)))
    }

    @Test fun idleEverythingIsOnButCancel() {
        assertEquals(listOf(true, true, false, true), rules(MenuState(hasSession = true)))
    }

    @Test fun paintingAHorizonTurnsTheSingleKeyCommandsOffAndNothingElse() {
        assertEquals(listOf(false, true, false, true), rules(MenuState(hasSession = true, paintingHorizon = true)))
    }

    @Test fun underTheProcessingScreenOnlyCancelStaysOn() {
        assertEquals(listOf(false, false, true, false), rules(MenuState(hasSession = true, modalUp = true, processing = true)))
    }

    @Test fun aRunGoingMakesCancelAvailableAndNothingElseDifferent() {
        assertEquals(listOf(true, true, true, true), rules(MenuState(hasSession = true, processing = true)))
    }

    @Test fun aVideoRenderingMakesRenderVideoUnavailableAndNothingElseDifferent() {
        assertEquals(listOf(true, true, false, false), rules(MenuState(hasSession = true, renderingVideo = true)))
    }
}
