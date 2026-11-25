package com.star.desktop.ui.app

import androidx.compose.ui.test.ComposeUiTest
import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.runComposeUiTest
import com.star.desktop.i18n.Strings
import com.star.desktop.ui.theme.StarTheme
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/** The alert over a run that stopped: Restart Now above OK when there is something to restart, OK alone otherwise, and never a path. */
@OptIn(ExperimentalTestApi::class)
class CriticalWarningDialogTest {
    @BeforeTest fun english() = Strings.setOverride("en")
    @AfterTest fun systemLanguage() = Strings.setOverride(null)

    private val config = "/tmp/star_temp_seq/config.json"
    private val restarted = mutableListOf<String>()
    private var acknowledged = 0

    private fun ComposeUiTest.show(restartable: String, suggestion: String = "") {
        val warning = com.star.proto.Warning.newBuilder()
            .setKind("previousRunDied").setSeverity("critical").setTitle("Previous Run Stopped")
            .setMessage("Star's previous run of seq stopped unexpectedly.").setSuggestion(suggestion)
            .setRestartableConfigPath(restartable).build()
        setContent {
            StarTheme { CriticalWarningDialog(warning, onOk = { acknowledged++ }, onRestart = { restarted.add(it) }) }
        }
    }

    @Test fun restartNowSitsAboveOkAndRestartsThatConfig() = runComposeUiTest {
        show(config)
        val restart = onNodeWithTag("warning.restart").assertIsDisplayed().fetchSemanticsNode().boundsInRoot
        val ok = onNodeWithTag("warning.ok").assertIsDisplayed().fetchSemanticsNode().boundsInRoot
        assertTrue(restart.bottom <= ok.top, "Restart Now $restart must be above OK $ok")
        assertEquals(restart.left, ok.left)
        assertEquals(restart.right, ok.right)
        onAllNodesWithText(config, substring = true).assertCountEquals(0)

        onNodeWithText("Restart Now").performClick()
        assertEquals(listOf(config), restarted)
        assertEquals(0, acknowledged)
    }

    @Test fun withNothingToRestartThereIsOnlyOk() = runComposeUiTest {
        val suggestion = "Its working files are no longer where it saved them, so it can't be restarted."
        show("", suggestion)
        onNodeWithTag("warning.restart").assertDoesNotExist()
        onAllNodesWithText("Restart Now").assertCountEquals(0)
        onNodeWithText(suggestion).assertIsDisplayed()
        onAllNodesWithText("config.json", substring = true).assertCountEquals(0)

        onNodeWithText("OK").performClick()
        assertEquals(1, acknowledged)
        assertEquals(emptyList(), restarted)
    }
}
