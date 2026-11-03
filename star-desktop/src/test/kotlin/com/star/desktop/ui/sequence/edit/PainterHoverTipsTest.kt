package com.star.desktop.ui.sequence.edit

import com.star.desktop.i18n.Strings
import com.star.desktop.i18n.localized
import java.io.File
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertNotEquals
import kotlin.test.assertTrue

/**
 * The painter's controls carry the hover texts the gui's `HorizonPainterView.swift` gives them (same key per state), and its save button reads
 * `ui.save_reference_horizon` and shows `ui.saving` while the save is going. Source scans, as `StartScreenTest` does.
 */
class PainterHoverTipsTest {
    @AfterTest fun reset() = Strings.setOverride(null)

    private fun read(path: String) = listOf(File(path), File("../$path")).first { it.isFile }.readText()

    private val source get() = read("star-desktop/src/main/kotlin/com/star/desktop/ui/sequence/edit/HorizonPainterView.kt")

    private val plainTips = listOf(
        "ui.paint_sky_adds_to_the_selection_p", "ui.erase_sky_removes_from_the_selection_e", "ui.discard_and_close_esc",
        "ui.shrink_brush", "ui.grow_brush",
        "ui.decrease_max_downward_extension_by_10px", "ui.increase_max_downward_extension_by_10px",
        "ui.max_pixels_the_refined_horizon_may_go_below", "ui.when_on_saving_this_reference_will_trigger",
    )

    @Test fun everyPainterControlHasTheGuisTip() {
        val src = source
        for (key in plainTips) assertTrue("HoverTip(localized(\"$key\"))" in src, "$key has no hover text in the painter")
        // the same choice of key per state as the gui
        assertTrue(
            "HoverTip(localized(if (phase == HorizonPhase.REFINEMENT) \"ui.reset_and_start_over_r\" else \"ui.reset_and_start_over_from_band_selection_r\"))" in src,
            "Reset does not pick its tip by phase",
        )
        assertTrue(
            "HoverTip(localized(if (startup) \"ui.save_horizon_continue\" else \"ui.save_horizon_reference\"))" in src,
            "Save does not pick its tip by startup mode",
        )
        // Sky and Ground are in two branches each (active one prominent), and both need the tip
        for (key in listOf("ui.paint_sky_adds_to_the_selection_p", "ui.erase_sky_removes_from_the_selection_e")) {
            val n = Regex(Regex.escape("HoverTip(localized(\"$key\"))")).findAll(src).count()
            assertTrue(n >= 2, "$key is on $n of the toggle's 2 buttons")
        }
        Strings.setOverride("en")
        for (key in plainTips + listOf("ui.reset_and_start_over_r", "ui.reset_and_start_over_from_band_selection_r", "ui.save_horizon_continue", "ui.save_horizon_reference")) {
            assertNotEquals(key, localized(key), "$key is missing from the catalogue")
        }
    }

    @Test fun theSaveButtonSaysWhatTheGuisSays() {
        val src = source
        assertTrue("localized(\"ui.save\")" !in src, "the painter still has the bare Save label")
        assertTrue("else if (hasMore) \"ui.next\" else \"ui.continue\"" in src && "if (!startup) \"ui.save_reference_horizon\"" in src, "Save does not read ui.save_reference_horizon")
        assertTrue("localized(\"ui.saving\")" in src, "no saving state")
        assertTrue("if (saving)" in src, "the saving state is not shown")
        Strings.setOverride("en")
        assertNotEquals("ui.saving", localized("ui.saving"))
        assertNotEquals("ui.save_reference_horizon", localized("ui.save_reference_horizon"))
    }
}
