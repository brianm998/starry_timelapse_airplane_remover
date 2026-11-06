package com.star.desktop.ui.dialogs

import com.star.desktop.i18n.Strings
import com.star.desktop.i18n.localized
import java.io.File
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertNotEquals
import kotlin.test.assertTrue

/** The render prompts' buttons and the frame-wait panel carry the hover texts the gui gives them. Source scans, as `StartScreenTest` does. */
class PromptHoverTipsTest {
    @AfterTest fun reset() = Strings.setOverride(null)

    private fun read(path: String) = listOf(File(path), File("../$path")).first { it.isFile }.readText()

    @Test fun thePromptButtonsAndWaitPanelHaveTheGuisTips() {
        val prompts = read("star-desktop/src/main/kotlin/com/star/desktop/ui/dialogs/RenderPromptDialogs.kt")
        val panel = read("star-desktop/src/main/kotlin/com/star/desktop/ui/sequence/ExtractionViews.kt")
        val tips = mapOf(
            prompts to listOf(
                "ui.start_processing_now_and_stop_showing_render", "ui.play_the_final_processed_frames_from_the", "ui.render_now_using_the_current_settings",
            ),
            panel to listOf("ui.tool_needs_extracted_frame"),
        )
        Strings.setOverride("en")
        for ((src, keys) in tips) for (key in keys) {
            assertTrue("HoverTip(localized(\"$key\"))" in src, "$key has no hover text")
            assertNotEquals(key, localized(key), "$key is missing from the catalogue")
        }
    }
}
