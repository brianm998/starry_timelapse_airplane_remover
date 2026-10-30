package com.star.desktop.domain

import com.star.desktop.i18n.Strings
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class PendingWorkTest {
    @BeforeTest fun english() = Strings.setOverride("en")
    @AfterTest fun systemLanguage() = Strings.setOverride(null)

    @Test fun nothingGoingOnIsNothingToConfirm() {
        assertFalse(PendingWork.NONE.isPending)
        assertEquals("", PendingWork.NONE.description())
    }

    @Test fun eachKindOfWorkIsPending() {
        assertTrue(PendingWork.NONE.copy(processing = true).isPending)
        assertTrue(PendingWork.NONE.copy(renderingFrames = true).isPending)
        assertTrue(PendingWork.NONE.copy(renderingVideo = true).isPending)
        assertTrue(PendingWork.NONE.copy(savingFrames = 1).isPending, "an edit still waiting to be written is work too")
    }

    @Test fun theWorkIsSaidInWordsTheMacAppUses() {
        assertEquals("processing frames", PendingWork.NONE.copy(processing = true).description())
        assertEquals("rendering video", PendingWork.NONE.copy(renderingVideo = true).description())
        assertEquals("saving 1 frame", PendingWork.NONE.copy(savingFrames = 1).description())
        assertEquals("saving 3 frames", PendingWork.NONE.copy(savingFrames = 3).description())
    }

    @Test fun severalKindsAreListedInOrder() {
        assertEquals(
            "processing frames, rendering video, saving 2 frames",
            PendingWork(processing = true, renderingFrames = false, renderingVideo = true, savingFrames = 2).description(),
        )
    }

    /** Rendering frames again has no words of its own, and is not said twice next to a run. */
    @Test fun renderingFramesReadsAsProcessingAndIsNotSaidTwice() {
        assertEquals("processing frames", PendingWork.NONE.copy(renderingFrames = true).description())
        assertEquals("processing frames", PendingWork.NONE.copy(processing = true, renderingFrames = true).description())
    }

    @Test fun theQuestionSaysWhatIsGoingOnAndWhatWouldHappenToIt() {
        val quit = CloseConfirmation(CloseAction.QUIT, "processing frames")
        assertEquals("Currently processing frames. Quitting now will interrupt this work.", quit.message)
        val close = CloseConfirmation(CloseAction.CLOSE_SESSION, "rendering video")
        assertEquals("Currently rendering video. Closing now will interrupt this work.", close.message)
        val open = CloseConfirmation(CloseAction.OPEN, "processing frames")
        assertEquals("Currently processing frames. Opening another sequence now will interrupt this work.", open.message)
    }

    @Test fun theButtonsNameWhatTheyDo() {
        assertEquals("Quit Anyway", com.star.desktop.i18n.localized(CloseAction.QUIT.confirmKey))
        assertEquals("Stop and Close", com.star.desktop.i18n.localized(CloseAction.CLOSE_SESSION.confirmKey))
        assertEquals("Stop and Open", com.star.desktop.i18n.localized(CloseAction.OPEN.confirmKey))
    }
}
