package com.star.desktop.ui.dialogs

import com.star.desktop.domain.ProcessingStepsInfo
import com.star.desktop.i18n.localized
import com.star.proto.CleanMethod
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertTrue

/** The info dialog beside the Processing Frames "Steps" heading; expected text comes from the catalogue, so the tests hold in any language. */
class ProcessingStepsInfoTest {
    private val everyStep = listOf(
        "horizon", "mergedHorizon", "starKeypoints", "earthKeypoints", "starHomography", "earthHomography", "horizonConsensus", "outliers", "merge",
    )

    private fun make(moving: Boolean = true, method: CleanMethod? = CleanMethod.CLEAN_AUTOMATIC, steps: List<String>, extraction: Boolean = false) =
        ProcessingStepsInfo.of(moving, method, steps, extraction)

    // A2: the opening

    @Test fun introNamesMovingAndModeForMovingAutomatic() {
        val info = make(moving = true, method = CleanMethod.CLEAN_AUTOMATIC, steps = listOf("merge"))
        assertEquals(localized("ui.steps_info_intro_moving", localized("ui.automatic")), info.intro)
        assertTrue(info.intro.contains(localized("ui.automatic")))
        assertEquals(localized("ui.steps_info_subtitle"), info.subtitle)
    }

    @Test fun introNamesStaticAndModeForStaticSelective() {
        val info = make(moving = false, method = CleanMethod.CLEAN_SELECTIVE, steps = listOf("merge"))
        assertEquals(localized("ui.steps_info_intro_static", localized("ui.selective")), info.intro)
        assertTrue(info.intro.contains(localized("ui.selective")))
        assertNotEquals(make(moving = true, method = CleanMethod.CLEAN_SELECTIVE, steps = listOf("merge")).intro, info.intro)
    }

    @Test fun introForAutoSelectiveMode() {
        val info = make(moving = true, method = CleanMethod.CLEAN_AUTOMATIC_TRUE, steps = listOf("merge"))
        assertEquals(localized("ui.steps_info_intro_moving", localized("ui.auto_selective")), info.intro)
        assertNotEquals(make(moving = true, method = CleanMethod.CLEAN_AUTOMATIC, steps = listOf("merge")).intro, info.intro)
    }

    // A3: exactly the steps the panel shows

    @Test fun entriesAreExactlyTheGivenStepsInOrder() {
        assertEquals(everyStep, make(steps = everyStep).entries.map { it.id })
        // A step the panel has dropped, from the middle of the list, is not listed.
        val without = everyStep.filter { it != "outliers" && it != "horizon" }
        assertEquals(without, make(steps = without).entries.map { it.id })
    }

    @Test fun staticRunWithoutEarthStepsListsNoEarthEntry() {
        val steps = listOf("horizon", "mergedHorizon", "starKeypoints", "starHomography", "merge")
        val ids = make(moving = false, steps = steps).entries.map { it.id }
        assertEquals(steps, ids)
        for (earth in listOf("earthKeypoints", "earthHomography", "horizonConsensus", "outliers")) assertFalse(ids.contains(earth), earth)
    }

    @Test fun extractionEntryComesFirstOnlyWhenShown() {
        val steps = listOf("starKeypoints", "starHomography", "merge")
        val shown = make(steps = steps, extraction = true)
        assertEquals(listOf("extraction") + steps, shown.entries.map { it.id })
        assertEquals(localized("ui.processing_step_extracting_video"), shown.entries.first().name)
        assertEquals(steps, make(steps = steps, extraction = false).entries.map { it.id })
        assertEquals(listOf("extraction"), make(steps = emptyList(), extraction = true).entries.map { it.id })
        assertTrue(make(steps = emptyList(), extraction = false).entries.isEmpty())
    }

    @Test fun typesThePanelHasNoRowForAreSkipped() {
        assertEquals(listOf("starKeypoints"), make(steps = listOf("preview", "starKeypoints", "alignmentValidation")).entries.map { it.id })
    }

    // A4: what each does and what it relies on

    @Test fun everyProcessingStepTypeHasWhatAndNeedsText() {
        val entries = make(steps = everyStep, extraction = true).entries
        assertEquals(10, entries.size)
        for (e in entries) {
            assertTrue(e.what.isNotEmpty(), "${e.id} has no description")
            assertTrue(e.needs.isNotEmpty(), "${e.id} has no dependency text")
            assertNotEquals(e.what, e.needs, e.id)
            assertFalse(e.what.contains("\n\n"), "${e.id}: only the first paragraph of the help")
            assertFalse(e.what.startsWith("ui."), "${e.id} shows a raw key")
            assertFalse(e.needs.startsWith("ui."), "${e.id} shows a raw key")
        }
        assertEquals(entries.size, entries.map { it.needs }.toSet().size)
        assertEquals(entries.size, entries.map { it.what }.toSet().size)
    }
}
