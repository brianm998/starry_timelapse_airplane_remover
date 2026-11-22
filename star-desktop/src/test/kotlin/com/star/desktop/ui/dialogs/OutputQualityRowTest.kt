package com.star.desktop.ui.dialogs

import com.star.proto.Config
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** The output JPEG quality row of the processing settings: starts at the input's quality, can be overridden, hidden for TIFF. */
class OutputQualityRowTest {
    @Test fun theSliderStartsAtTheInputsQualityForJpeg() {
        assertTrue(OutputQuality.visible(83))
        assertEquals(83, OutputQuality.shown(override = 0, sourceQuality = 83))
        assertTrue(OutputQuality.matchesInput(0, 83))
    }

    @Test fun theRowIsHiddenWhenTheFramesAreNotJpeg() {
        assertFalse(OutputQuality.visible(0))
    }

    @Test fun movingTheSliderOverridesAndResetClears() {
        val override = OutputQuality.overrideFor(60, 83)
        assertEquals(60, override)
        assertEquals(60, OutputQuality.shown(override, 83))
        assertFalse(OutputQuality.matchesInput(override, 83))
        // the reset control sends 0
        assertEquals(83, OutputQuality.shown(0, 83))
    }

    @Test fun landingOnTheInputsQualityIsNoOverride() {
        assertEquals(0, OutputQuality.overrideFor(83, 83))
        assertEquals(100, OutputQuality.overrideFor(1000, 83))
        assertEquals(1, OutputQuality.overrideFor(-5, 83))
    }

    private fun proposal(applied: Config, quality: Int): Config {
        val base = noEditsProposal(applied)
        val edit = SettingsEdit(applied.horizonDetectionEnabled, applied.tripodHeadWasMoving, applied.cleanMethod, false) { false }
        return proposedConfig(
            applied, applied.cleanMethod, applied.detectionType, applied.horizonDetectionEnabled, applied.tripodHeadWasMoving,
            applied.numberOfFramesToProcessConcurrently.coerceAtLeast(1), "full", edit, emptyMap(), emptyMap(), 1, quality,
        ).also { assertFalse(base.hasOutputJpegQuality()) }
    }

    @Test fun anOverrideIsSentAndAnUntouchedRowIsNot() {
        val applied = Config.newBuilder().build()
        assertFalse(proposal(applied, 0).hasOutputJpegQuality())
        assertEquals(60, proposal(applied, 60).outputJpegQuality)
        // taking an applied override back sends 0
        val withOverride = Config.newBuilder().setOutputJpegQuality(60).build()
        assertFalse(proposal(withOverride, 60).hasOutputJpegQuality())
        assertTrue(proposal(withOverride, 0).hasOutputJpegQuality())
        assertEquals(0, proposal(withOverride, 0).outputJpegQuality)
    }
}
