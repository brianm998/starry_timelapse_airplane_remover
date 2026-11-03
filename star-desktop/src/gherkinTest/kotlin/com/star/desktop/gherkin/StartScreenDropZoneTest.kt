package com.star.desktop.gherkin

import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.getBoundsInRoot
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.runDesktopComposeUiTest
import androidx.compose.ui.unit.dp
import com.star.desktop.i18n.localized
import com.star.desktop.ui.app.AppViewModel
import com.star.desktop.ui.initial.InitialView
import com.star.desktop.ui.initial.NO_INTRO_VIDEO_PROPERTY
import kotlin.test.Test
import kotlin.test.assertTrue

/**
 * The start screen's drop zone is the gui's: it takes the middle of the window, between the Learn button and the Load buttons, not a 160dp strip
 * in a 560dp column.
 *
 *     ./gradlew gherkinTest --tests '*StartScreenDropZoneTest*'
 */
@OptIn(ExperimentalTestApi::class)
class StartScreenDropZoneTest {
    @Test fun theDropZoneFillsTheMiddleOfTheWindow() {
        System.setProperty(NO_INTRO_VIDEO_PROPERTY, "1")
        // The view model resolves a stard path when it is made, though this test never starts the engine: any executable file will do.
        val stard = kotlin.io.path.createTempFile("stard").toFile().apply { setExecutable(true); deleteOnExit() }
        System.setProperty("star.stard.path", stard.absolutePath)
        try {
            runDesktopComposeUiTest(width = 1400, height = 1100) {
                setContent {
                    val scope = rememberCoroutineScope()
                    InitialView(AppViewModel(scope, releaseCheck = { null }))
                }
                waitForIdle()
                val zone = onNodeWithTag("startup.dropzone", useUnmergedTree = true).getBoundsInRoot()
                val learn = onNodeWithText(localized("ui.learn_about_star"), useUnmergedTree = true).getBoundsInRoot()
                val load = onNodeWithText(localized("ui.load_video"), useUnmergedTree = true).getBoundsInRoot()
                val height = zone.bottom - zone.top
                val width = zone.right - zone.left
                assertTrue(height >= 550.dp, "the drop zone is $height high in a 1100dp window")
                assertTrue(width > 900.dp, "the drop zone is $width wide in a 1400dp window")
                assertTrue(zone.top >= learn.bottom, "the zone (${zone.top}) starts above the Learn button's bottom (${learn.bottom})")
                assertTrue(zone.bottom <= load.top, "the zone (${zone.bottom}) ends below the top of the Load buttons (${load.top})")
            }
        } finally {
            System.clearProperty(NO_INTRO_VIDEO_PROPERTY)
            System.clearProperty("star.stard.path")
        }
    }
}
