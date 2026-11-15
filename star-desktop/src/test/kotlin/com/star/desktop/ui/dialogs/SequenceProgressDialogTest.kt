package com.star.desktop.ui.dialogs

import java.io.File
import kotlin.test.Test
import kotlin.test.assertTrue

/**
 * The reopen panel's Settings button (macOS `SequenceProgressSettingsWiringTests`). `AppViewModel` cannot be built in a test (see
 * `MainWindowCloseTest`), so the wiring is read from the sources; the footer's order is pinned on `ReopenVerdict.footer` in `ReopenVerdictTest`.
 */
class SequenceProgressDialogTest {
    private fun source(path: String) = listOf(File("src/main/kotlin/com/star/desktop/$path"), File("star-desktop/src/main/kotlin/com/star/desktop/$path")).first { it.isFile }.readText()

    @Test fun settingsClosesThePanelEntersEditModeAndOpensTheSettings() {
        val body = source("ui/app/AppViewModel.kt").substringAfter("fun openSettingsForOpenedSequence() {").substringBefore("}")
        val close = body.indexOf("closeSequenceProgress()")
        val edit = body.indexOf("setMode(com.star.desktop.domain.InteractionMode.EDIT)")
        val settings = body.indexOf("openSettings()")
        assertTrue(close >= 0 && edit > close && settings > edit, "not close, then edit mode, then the settings: $body")
    }

    @Test fun theFooterIsBuiltFromTheVerdictWithSettingsTagged() {
        val dialog = source("ui/dialogs/SequenceProgressDialog.kt")
        assertTrue("for (button in verdict.footer)" in dialog, "the footer is not built from the verdict's footer")
        val settings = dialog.substringAfter("SequenceProgressButton.SETTINGS ->").substringBefore("SequenceProgressButton.ACTION ->")
        assertTrue("onClick = app::openSettingsForOpenedSequence" in settings, "Settings does not open the settings")
        assertTrue("testTag(button.testTag!!)" in settings, "Settings is not tagged sequenceprogress.settings")
        assertTrue("localized(\"ui.settings\")" in settings)
    }
}
