package com.star.desktop.ui.app

import java.io.File
import kotlin.test.Test
import kotlin.test.assertTrue

/**
 * The `@ui` features that look for a secondary window (`uiSecondaryWindowToggles`, `uiSequenceWindowsGoWithIt`) cannot see an AWT window from the
 * Compose test host, so they read the view model's flag for it. This holds `Main.kt` to the flag: each window is shown for it and closing it clears
 * it, and the two that are about a sequence are shown only with one open.
 */
class SecondaryWindowsWiringTest {
    private val source: String =
        listOf(File("src/main/kotlin/com/star/desktop/Main.kt"), File("star-desktop/src/main/kotlin/com/star/desktop/Main.kt")).first { it.isFile }.readText()

    @Test fun eachSecondaryWindowIsShownForItsFlagAndClosesIt() {
        for ((flag, close) in listOf(
            "showOutlierWindow" to "closeOutlierWindow",
            "showAlignmentWindow" to "closeAlignmentWindow",
            "showBlobWindow" to "closeBlobWindow",
            "showDebugWindow" to "closeDebugWindow",
        )) {
            assertTrue(Regex("""by vm\.$flag\.collectAsState\(\)""").containsMatchIn(source), "Main.kt does not read vm.$flag")
            assertTrue("onCloseRequest = vm::$close" in source, "Main.kt's window for $flag does not close with vm::$close")
        }
    }

    @Test fun theWindowsAboutASequenceAreShownOnlyWithOne() {
        assertTrue("if (showOutlier && svm != null)" in source, "the outlier window is shown without a sequence")
        assertTrue("if (showAlign && svm != null)" in source, "the alignment window is shown without a sequence")
    }
}
