package com.star.desktop.ui.app

import com.star.desktop.domain.MainWindowClose
import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * M10 (D10) of the parity plan: closing the main window on a Mac unloads the sequence and keeps the app running, as the gui's
 * `windowShouldClose` does, and asks first ("Close Anyway") if work would be interrupted. Windows and Linux still quit. Compose has no test host
 * for windows (§6.3) and `AppViewModel` cannot be built in a test, so the wiring is read from the sources.
 */
class MainWindowCloseTest {
    private fun source(path: String) = listOf(File("src/main/kotlin/com/star/desktop/$path"), File("star-desktop/src/main/kotlin/com/star/desktop/$path")).first { it.isFile }.readText()

    @Test fun aMacKeepsRunningAndTheOthersQuit() {
        assertEquals(MainWindowClose.UNLOAD_AND_HIDE, MainWindowClose.forSystem("Mac OS X"))
        assertEquals(MainWindowClose.QUIT, MainWindowClose.forSystem("Windows 11"))
        assertEquals(MainWindowClose.QUIT, MainWindowClose.forSystem("Linux"))
    }

    @Test fun theMainWindowsCloseButtonGoesThroughTheCloseRule() {
        val main = source("Main.kt")
        assertTrue("onCloseRequest = vm::requestCloseWindow" in main, "the main window's close button is not the close rule")
        assertTrue("visible = mainVisible" in main, "the main window cannot be hidden")
        assertTrue("AppReopenedListener" in main && "AppForegroundListener" in main, "nothing brings the window back")
        assertTrue("vm.requestQuit()" in main, "Cmd-Q no longer asks")
        assertEquals(1, Regex("""onCloseRequest = vm::requestCloseWindow""").findAll(main).count(), "only the main window does this")
    }

    @Test fun theRuleQuitsOrUnloadsAndHidesAfterTheQuestion() {
        val app = source("ui/app/AppViewModel.kt")
        val rule = app.substringAfter("fun requestCloseWindow()").substringBefore("fun reopenMainWindow()")
        assertTrue("MainWindowClose.QUIT) { requestQuit(); return }" in rule, "where the app quits, closing the window is a quit")
        assertTrue("CloseAction.CLOSE_WINDOW" in rule && "closeWindowNow()" in rule, "the question, then the close")
        val close = app.substringAfter("private fun closeWindowNow()").substringBefore("/** Cmd-Q")
        assertTrue("unloadSession()" in close && "_mainWindowVisible.value = false" in close, "the sequence is unloaded and the window hidden")
        assertTrue("CloseAction.CLOSE_WINDOW -> closeWindowNow()" in app, "the question's yes does not close the window")
    }
}
