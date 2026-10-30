package com.star.desktop.ui.sequence

import java.io.File
import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * Q6, L4 and L5 of the parity plan (owner decisions D7 and D8): the left panel has the images to show and how they are shown, as the gui's does, and
 * no Processing and Render blocks: every one of those actions is in the Actions menu (`gherkin/ui/commands.json`, which both clients are held to).
 * "Render All Frames" is a run over the sequence with the question about rendering the video, as the gui's, and not a separate pass.
 */
class LeftPanelTest {
    private fun read(path: String) = listOf(File(path), File("../$path")).first { it.isFile }.readText()
    private val panel = read("star-desktop/src/main/kotlin/com/star/desktop/ui/sequence/LeftPanel.kt")
    private val menu = read("star-desktop/src/main/kotlin/com/star/desktop/ui/app/StarMenuBar.kt")

    @Test fun theLeftPanelHasNoProcessingOrRenderBlocks() {
        for (gone in listOf("process_frames_from_here", "process_current_frame", "reprocess_current_force", "find_outliers_for_this_frame",
            "render_current_frame", "render_all_frames", "render.all.frames", "cancelProcessing")) {
            assertFalse(gone in panel, "the left panel still has $gone")
        }
        assertTrue("ShowViewModes(vm)" in panel && "DisplaySection(vm)" in panel, "the images to show and the display options stay")
        assertTrue("processing.progress" in panel, "the progress node the Gherkin runners wait on stays")
    }

    @Test fun everyActionTheBlocksHadIsInTheMenu() {
        for (key in listOf("ui.process_frames_from_here_to_the_end", "ui.process_current_frame", "ui.re_process_this_frame_from_the_start",
            "ui.find_outliers_for_this_frame", "ui.render_this_frame", "ui.render_all_frames", "ui.cancel_processing")) {
            assertTrue("localized(\"$key\")" in menu, "$key is not a menu item")
        }
        assertTrue("Item(localized(\"ui.render_all_frames\"), enabled = hasSession) { app.requestProcessAll() }" in menu, "Render All Frames is Process All with its question")
        assertFalse(".renderAllFrames()" in menu)
    }
}
