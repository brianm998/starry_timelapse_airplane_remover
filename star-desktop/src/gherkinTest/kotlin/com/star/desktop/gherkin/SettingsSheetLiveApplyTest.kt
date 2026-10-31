package com.star.desktop.gherkin

import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.SemanticsNodeInteraction
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.hasSetTextAction
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.isToggleable
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.printToString
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performKeyInput
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performTextReplacement
import androidx.compose.ui.test.pressKey
import androidx.compose.ui.test.runDesktopComposeUiTest
import androidx.compose.ui.input.key.Key
import com.star.desktop.i18n.localized
import com.star.desktop.ui.app.AppScreen
import com.star.desktop.ui.app.AppViewModel
import com.star.desktop.ui.app.StarApp
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.runBlocking
import java.awt.Color
import java.awt.image.BufferedImage
import java.io.File
import java.nio.file.Files
import javax.imageio.ImageIO
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * P5 (D4) of the parity plan against a real `stard`: the settings sheet applies an edit as it is made, a setting put back is sent again, a number
 * is taken on Return and not as typed, one outside its range is never applied, and Dismiss closes. The unit tests check what is sent
 * (`SettingsLiveApplyTest`); this checks that the sheet sends it and the daemon ends up holding it.
 *
 *     ./gradlew gherkinTest -Pstar.stard.path=$PWD/../daemon/.build/debug/stard --tests '*SettingsSheetLiveApplyTest*'
 */
@OptIn(ExperimentalTestApi::class)
class SettingsSheetLiveApplyTest {
    private fun makeSequence(dir: File, frames: Int = 6) {
        dir.mkdirs()
        for (n in 1..frames) {
            val img = BufferedImage(320, 200, BufferedImage.TYPE_INT_RGB)
            for (y in 0 until 200) for (x in 0 until 320) img.setRGB(x, y, Color(10, 10, 14 + y / 20).rgb)
            ImageIO.write(img, "jpg", File(dir, "frame_%03d.jpg".format(n)))
        }
    }

    private fun label(key: String) = localized(key).removeSuffix(":")

    @Test fun editsApplyAsTheyAreMadeAndNumbersOnReturn() {
        val scratch = Files.createTempDirectory("star-live-apply-").toFile()
        val realHome = System.getProperty("user.home")
        System.setProperty("user.home", File(scratch, "home").apply { mkdirs() }.absolutePath)
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        try {
            val sequence = File(scratch, "seq").also { makeSequence(it) }
            val model = AppViewModel(scope, autoOpenPath = sequence.absolutePath, autoMode = "settings", autoFrame = 0, releaseCheck = { null })
            runDesktopComposeUiTest(width = 1400, height = 1100) {
                val deadline = System.nanoTime() + 180_000_000_000L
                while (model.screen.value !is AppScreen.Sequence) {
                    model.error.value?.let { error("opening the sequence failed: $it") }
                    check(System.nanoTime() < deadline) { "timed out waiting for the sequence to open" }
                    Thread.sleep(50)
                }
                setContent { StarApp(model) }

                fun config() = runBlocking { model.sessions.getConfig() }
                // The daemon answers on real threads and the sheet's debounce runs on the test clock: look until it is so, or give up.
                fun until(what: String, ms: Long = 10_000, condition: () -> Boolean) {
                    val end = System.currentTimeMillis() + ms
                    while (!condition()) {
                        if (System.currentTimeMillis() >= end) {
                            println("SEMANTICS at the timeout of \"$what\":\n" + onRoot(useUnmergedTree = true).printToString(maxDepth = 60))
                            error("timed out: $what (error shown: ${model.error.value}; settings up: ${model.showSettings.value})")
                        }
                        waitForIdle(); Thread.sleep(100)
                    }
                }
                // The sheet sits under a scrim that is a (disabled) clickable, which merges everything below it, so a control cannot be found
                // by its sibling label: it is the control on the same line as the label.
                fun beside(key: String, kind: SemanticsMatcher): SemanticsNodeInteraction {
                    val y = onNode(hasText(label(key)), useUnmergedTree = true).fetchSemanticsNode().boundsInRoot.center.y
                    val i = onAllNodes(kind, useUnmergedTree = true).fetchSemanticsNodes().indexOfFirst { y in it.boundsInRoot.top..it.boundsInRoot.bottom }
                    check(i >= 0) { "nothing on the line of ${label(key)}" }
                    return onAllNodes(kind, useUnmergedTree = true)[i]
                }
                fun toggle(key: String) = beside(key, isToggleable())
                fun field(key: String) = beside(key, hasSetTextAction())

                until("the sheet is up") { runCatching { onNodeWithText(localized("ui.show_expert_settings")).assertExists() }.isSuccess }
                onNodeWithText(localized("ui.show_expert_settings")).performClick()
                until("the alignment group") { runCatching { onNodeWithText(localized("ui.alignment_settings")).assertExists() }.isSuccess }
                onNodeWithText(localized("ui.alignment_settings")).performClick()
                until("the earth alignment row") { runCatching { toggle("ui.allow_earth_alignment").assertExists() }.isSuccess }

                // A toggle applies by itself, and putting it back is sent again.
                val earth = config().allowEarthAlignment
                toggle("ui.allow_earth_alignment").performClick()
                until("the daemon holds the toggled setting") { config().allowEarthAlignment == !earth }
                toggle("ui.allow_earth_alignment").performClick()
                until("the daemon holds the setting put back") { config().allowEarthAlignment == earth }

                // A number is taken on Return, not as it is typed; a value out of range is never applied.
                val keypoints = config().alignmentMaxKeypoints
                val typed = if (keypoints == 1234) 1235 else 1234
                field("ui.max_keypoints").performTextReplacement("$typed")
                Thread.sleep(1_200); waitForIdle()
                assertEquals(keypoints, config().alignmentMaxKeypoints, "a number still being typed was applied")
                field("ui.max_keypoints").performKeyInput { pressKey(Key.Enter) }
                until("the daemon holds the number") { config().alignmentMaxKeypoints == typed }

                field("ui.max_keypoints").performTextReplacement("999999")
                field("ui.max_keypoints").performKeyInput { pressKey(Key.Enter) }
                Thread.sleep(1_200); waitForIdle()
                assertEquals(typed, config().alignmentMaxKeypoints, "a value out of range was applied")
                onNodeWithText(localized("ui.enter_a_whole_number_from_a_to_b", 4, 10000), useUnmergedTree = true).assertExists()

                // Dismiss closes the sheet.
                // With the expert groups open the sheet is taller than the window, and its buttons are at the bottom of what scrolls.
                onNodeWithText(localized("ui.dismiss")).performScrollTo().performClick()
                until("the sheet closes") { !model.showSettings.value }
                assertFalse(model.showSettings.value)
                assertTrue(model.error.value == null, "an error was shown: ${model.error.value}")
            }
        } finally {
            scope.cancel()
            System.setProperty("user.home", realHome)
            scratch.deleteRecursively()
        }
    }
}
