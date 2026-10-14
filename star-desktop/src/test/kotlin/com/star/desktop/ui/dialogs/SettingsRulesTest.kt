package com.star.desktop.ui.dialogs

import com.star.desktop.domain.SettingsEdit
import com.star.proto.CleanMethod
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** Which settings rows apply to what is being edited (macOS `ProcessingSettingsView`'s `.disabled(...)`s). */
class SettingsRulesTest {
    private val all: List<ExpertField> = ALIGNMENT_FIELDS + HORIZON_FIELDS + MEMORY_FIELDS + PERFORMANCE_FIELDS

    private fun field(label: String) = all.single { it.label == label }

    private fun edit(
        horizon: Boolean = true, moving: Boolean = true, clean: CleanMethod = CleanMethod.CLEAN_SELECTIVE, gpuUnavailable: Boolean = false,
        vararg on: String,
    ) = SettingsEdit(horizon, moving, clean, gpuUnavailable) { it in on }

    private fun enabled(label: String, e: SettingsEdit) = field(label).enabled(e)

    private val horizonRows = listOf("Canny edge detection", "Canny min threshold", "Canny max threshold", "Canny L2 gradient", "Homography smoothing ε")
    private val referenceRows = listOf(
        "Reference horizon smoothing", "Smoothing max distance", "Brightness refinement", "Refinement search radius", "Refinement hist buckets",
        "Neighborhood size", "Spike removal", "Spike max width", "Spike max deviation", "Spike window half",
    )
    private val everything = arrayOf("Canny edge detection", "Reference horizon smoothing", "Brightness refinement", "Spike removal")

    @Test fun aSkyOnlySequenceHasNoHorizonToTune() {
        val e = edit(horizon = false, on = everything)
        for (label in horizonRows + referenceRows) assertFalse(enabled(label, e), "$label applies to a sequence with no horizon")
    }

    @Test fun aFixedCameraHasNoReferenceHorizonsToSmoothBetween() {
        val e = edit(horizon = true, moving = false, on = everything)
        for (label in referenceRows) assertFalse(enabled(label, e), "$label applies to a camera that did not move")
        // The ordinary horizon rows still do.
        for (label in horizonRows) assertTrue(enabled(label, e), "$label should apply to a fixed camera with a horizon")
    }

    @Test fun aMovingCameraWithAHorizonHasEveryHorizonRowOnceTheTogglesAboveAreOn() {
        val e = edit(on = everything)
        for (label in horizonRows + referenceRows) assertTrue(enabled(label, e), label)
    }

    @Test fun aSubSettingMeansNothingWhileItsParentIsOff() {
        val noCanny = edit(on = arrayOf("Reference horizon smoothing", "Brightness refinement", "Spike removal"))
        for (label in listOf("Canny min threshold", "Canny max threshold", "Canny L2 gradient")) assertFalse(enabled(label, noCanny), label)
        assertTrue(enabled("Canny edge detection", noCanny), "the toggle itself is still there to turn on")

        val noSmoothing = edit(on = arrayOf("Canny edge detection", "Brightness refinement", "Spike removal"))
        assertFalse(enabled("Smoothing max distance", noSmoothing))
        assertTrue(enabled("Reference horizon smoothing", noSmoothing))

        val noBrightness = edit(on = arrayOf("Spike removal"))
        for (label in listOf("Refinement search radius", "Refinement hist buckets", "Neighborhood size", "Spike removal")) {
            assertFalse(enabled(label, noBrightness), "$label needs brightness refinement")
        }
        assertTrue(enabled("Brightness refinement", noBrightness))

        val noSpikes = edit(on = arrayOf("Brightness refinement"))
        for (label in listOf("Spike max width", "Spike max deviation", "Spike window half")) assertFalse(enabled(label, noSpikes), "$label needs spike removal")
        assertTrue(enabled("Spike removal", noSpikes))
    }

    @Test fun staticNeighborsAreForACameraThatStayedPut() {
        assertTrue(enabled("Static neighbor frames", edit(moving = false)))
        assertFalse(enabled("Static neighbor frames", edit(moving = true)))
        assertTrue(enabled("Neighbor frames", edit(moving = false)))
        assertTrue(enabled("Neighbor frames", edit(moving = true)))
    }

    @Test fun theGpuTogglesAreOffOnAMachineWithoutOne() {
        for (f in PERFORMANCE_FIELDS) {
            assertFalse(f.enabled(edit(gpuUnavailable = true)), f.label)
            assertTrue(f.enabled(edit(gpuUnavailable = false)), f.label)
        }
    }

    @Test fun theMemorySettingsAlwaysApply() {
        for (f in MEMORY_FIELDS) assertTrue(f.enabled(edit(horizon = false, moving = false)), f.label)
    }

    /** What decides how strictly outliers are looked for applies to whatever finds them: Selective and Auto-Selective, not Automatic. */
    @Test fun theDetectionStrengthAppliesWhenTheMethodUsesOutliers() {
        assertFalse(edit(clean = CleanMethod.CLEAN_AUTOMATIC).usesOutliers)
        assertTrue(edit(clean = CleanMethod.CLEAN_AUTOMATIC_TRUE).usesOutliers)
        assertTrue(edit(clean = CleanMethod.CLEAN_SELECTIVE).usesOutliers, "Selective always uses them, whatever auto-preservation was left at")
    }

    // ---- the ranges

    @Test fun theNeighborCountsCannotExceedTheOtherFramesThereAre() {
        val neighbors = field("Neighbor frames") as IntField
        assertEquals(9, neighbors.maxFor(10))
        assertEquals(1, neighbors.maxFor(2))
        assertEquals(1, neighbors.maxFor(1), "a one-frame sequence still has a minimum to stand on")
        assertEquals(1000, neighbors.maxFor(5000), "and a long one is held to the field's own limit")
        assertTrue(neighbors.isValid("9", 10))
        assertFalse(neighbors.isValid("10", 10))
    }

    @Test fun theDocumentedRangesAreInclusiveAtBothEnds() {
        val divisor = field("Keypoint detection divisor") as DoubleField
        assertTrue(divisor.isValid("1", 1))
        assertTrue(divisor.isValid("8", 1), "8 is offered, so 8 is accepted")
        assertFalse(divisor.isValid("0.99", 1))
        assertFalse(divisor.isValid("8.01", 1))

        val canny = field("Canny min threshold") as DoubleField
        assertEquals(1.0, canny.min)
        assertEquals(300.0, canny.max)
        val epsilon = field("Homography smoothing ε") as DoubleField
        assertEquals(0.0 to 10.0, epsilon.min to epsilon.max)
        val spike = field("Spike max deviation") as DoubleField
        assertEquals(0.001 to 0.5, spike.min to spike.max)
    }

    @Test fun everyRowHasItsWordsInTheCatalogue() {
        com.star.desktop.i18n.Strings.setOverride("en")
        try {
            for (f in all) assertFalse(com.star.desktop.i18n.localized(f.labelKey) == f.labelKey, "${f.label}: ${f.labelKey} is not in the catalogue")
        } finally {
            com.star.desktop.i18n.Strings.setOverride(null)
        }
    }

    // ---- the explanations

    /** Every setting has something to say about itself (macOS's (i) on each row), and says it in the user's language. */
    @Test fun everySettingHasHelpInTheCatalogue() {
        com.star.desktop.i18n.Strings.setOverride("en")
        try {
            for (f in all) {
                assertTrue(f.helpKeys.isNotEmpty(), "${f.label} has no help")
                for (key in f.helpKeys) {
                    val text = com.star.desktop.i18n.localized(key)
                    assertFalse(text == key, "${f.label}: $key is not in the catalogue")
                    assertTrue(text.length > 20, "${f.label}: $key says too little: $text")
                }
                assertTrue(f.helpText()!!.isNotBlank())
            }
        } finally {
            com.star.desktop.i18n.Strings.setOverride(null)
        }
    }

    @Test fun aYesNoSettingExplainsBothOfItsChoices() {
        assertEquals(2, field("Canny edge detection").helpKeys.size)
        assertEquals(2, field("Canny L2 gradient").helpKeys.size)
        assertTrue(field("Canny edge detection").helpText()!!.contains("\n\n"), "a paragraph for each")
    }

    @Test fun helpIsKeptForRealFieldsOnly() {
        val labels = all.map { it.label }.toSet()
        assertEquals(emptySet(), FIELD_HELP.keys - labels, "help for a setting that is not there")
    }

    @Test fun everyTranslationOfTheHelpIsThere() {
        for (code in com.star.desktop.i18n.Strings.languages.map { it.code }) {
            com.star.desktop.i18n.Strings.setOverride(code)
            try {
                for (f in all) for (key in f.helpKeys) {
                    val text = com.star.desktop.i18n.localized(key)
                    assertFalse(text == key || text.isBlank(), "$code: ${f.label} / $key")
                }
            } finally {
                com.star.desktop.i18n.Strings.setOverride(null)
            }
        }
    }
}
