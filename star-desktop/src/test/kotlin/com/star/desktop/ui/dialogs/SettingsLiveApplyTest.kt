package com.star.desktop.ui.dialogs

import com.star.desktop.domain.SettingsEdit
import com.star.proto.CleanMethod
import com.star.proto.Config
import com.star.proto.DetectionType
import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * P5 (D4) and P8 of the parity plan: the settings sheet applies edits as they are made, as the gui's does, and is laid out as the gui's is. What
 * is sent is the settings that differ from what the daemon holds now; the layout, which Compose has no window test host for (§6.3), is read
 * from the source.
 */
class SettingsLiveApplyTest {
    /** What the daemon holds: a config as it sends one (every field present), with a number the engine picked for itself. */
    private val base: Config = Config.newBuilder()
        .setCleanMethod(CleanMethod.CLEAN_SELECTIVE).setDetectionType(DetectionType.DETECTION_STRONG)
        .setHorizonDetectionEnabled(true).setTripodHeadWasMoving(false)
        .setNumberOfFramesToProcessConcurrently(0)          // 0 reads as 1: the sheet's own floor, not an edit
        .setResourceProfile("full")
        .setAllowEarthAlignment(false)
        .setAlignmentKeypointDetectionDivisor(1.0)
        .setNumberAlignedNeighborFrames(5)
        .setHomographySmoothingEpsilon(0.5)
        .build()

    private fun proposal(
        applied: Config = base,
        clean: CleanMethod = applied.cleanMethod,
        horizon: Boolean = applied.horizonDetectionEnabled,
        bools: Map<String, Boolean> = emptyMap(),
        texts: Map<String, String> = emptyMap(),
        frameMax: Int = 100,
    ): Config {
        val edit = SettingsEdit(horizon, applied.tripodHeadWasMoving, clean, false) { bools[it] ?: false }
        return proposedConfig(
            applied, clean, applied.detectionType, horizon, applied.tripodHeadWasMoving, 1,
            applied.resourceProfile, edit, bools, texts, frameMax,
        )
    }

    @Test fun openingTheSheetAndChangingNothingChangesNothing() {
        assertEquals(noEditsProposal(base), proposal(), "an edit was found where there is none, so the sheet would apply something as it opens")
        assertEquals(base.cleanMethod, proposal().cleanMethod, "the basic choices are always sent: the daemon takes them whole")
        assertTrue(proposal().horizonDetectionEnabled, "a horizon left out would be switched off")
    }

    @Test fun anEditedSettingIsSentAndNothingElseIs() {
        val sent = proposal(bools = mapOf("Allow earth alignment" to true))
        assertTrue(sent.hasAllowEarthAlignment() && sent.allowEarthAlignment)
        assertEquals(noEditsProposal(base).toBuilder().setAllowEarthAlignment(true).build(), sent, "something besides the edit was sent")
        assertFalse(sent.hasAlignmentKeypointDetectionDivisor(), "the number the engine picked for itself was marked as chosen")
    }

    /** The reason for comparing with what the daemon holds, not with what the sheet opened on. */
    @Test fun aSettingPutBackAfterItWasAppliedIsSentAgain() {
        val appliedAfterTheFirstEdit = base.toBuilder().setAllowEarthAlignment(true).build()
        val sent = proposal(applied = appliedAfterTheFirstEdit, bools = mapOf("Allow earth alignment" to false))
        assertTrue(sent.hasAllowEarthAlignment() && !sent.allowEarthAlignment, "the daemon would have stayed on the first edit")
        // Against the config the sheet opened on, switching it off again would be no change at all.
        assertEquals(noEditsProposal(base), proposal(bools = mapOf("Allow earth alignment" to false)))
    }

    @Test fun aNumberTakenInIsSentOnceItIsValidAndDifferent() {
        assertEquals(7, proposal(texts = mapOf("Neighbor frames" to "7")).numberAlignedNeighborFrames)
        assertEquals(noEditsProposal(base), proposal(texts = mapOf("Neighbor frames" to "5")), "the value already in force")
        assertEquals(noEditsProposal(base), proposal(texts = mapOf("Keypoint detection divisor" to "1")), "the engine's own 1.0")
    }

    @Test fun aNumberOutOfItsRangeIsNeverSent() {
        assertFalse(proposal(texts = mapOf("Neighbor frames" to "5000")).hasNumberAlignedNeighborFrames())
        assertFalse(proposal(texts = mapOf("Neighbor frames" to "")).hasNumberAlignedNeighborFrames())
        // A neighbour count cannot be more than the sequence has frames, less one.
        assertEquals(9, proposal(texts = mapOf("Neighbor frames" to "9"), frameMax = 10).numberAlignedNeighborFrames)
        assertFalse(proposal(texts = mapOf("Neighbor frames" to "10"), frameMax = 10).hasNumberAlignedNeighborFrames())
    }

    @Test fun aRowThatDoesNotApplyIsNotSent() {
        // A sky-only sequence has no horizon to smooth.
        assertFalse(proposal(horizon = false, texts = mapOf("Homography smoothing ε" to "2")).hasHomographySmoothingEpsilon())
        assertTrue(proposal(horizon = true, texts = mapOf("Homography smoothing ε" to "2")).hasHomographySmoothingEpsilon())
    }

    @Test fun theBasicChoicesAreSentWhenTheyChange() {
        val sent = proposal(clean = CleanMethod.CLEAN_AUTOMATIC_TRUE)
        assertEquals(CleanMethod.CLEAN_AUTOMATIC_TRUE, sent.cleanMethod)
    }

    // ---- P5 and P8: what the sheet looks like, from its source

    private val dialog = listOf(File("src/main/kotlin/com/star/desktop/ui/dialogs/ProcessingSettingsDialog.kt"), File("star-desktop/src/main/kotlin/com/star/desktop/ui/dialogs/ProcessingSettingsDialog.kt"))
        .first { it.isFile }.readText()

    @Test fun theSheetHasDismissAndNotCancelAndSave() {
        assertTrue("localized(\"ui.dismiss\")" in dialog)
        assertFalse("localized(\"ui.cancel\")" in dialog, "Cancel: edits apply as they are made")
        assertFalse("localized(\"ui.save\")" in dialog, "Save: edits apply as they are made")
        assertTrue("LaunchedEffect(proposed, applied)" in dialog, "nothing applies the edits as they settle")
    }

    @Test fun numbersAreTakenOnReturnOrLeavingTheField() {
        assertTrue(".numberFieldRules(commit = onCommit, revert = onRevert)" in dialog, "a half-typed number would be applied")
    }

    @Test fun theLayoutIsTheGuis() {
        assertTrue("BoxWithConstraints" in dialog && "TWO_COLUMNS_FROM" in dialog, "two columns")
        assertEquals(3, Regex("""collapsible = true""").findAll(dialog).count(), "alignment, horizon and memory are folded until opened")
        assertTrue("app.setShowExpertSettings(!showExpert)" in dialog, "the expert toggle is a button")
        assertFalse("ToggleRow(localized(if (showExpert)" in dialog, "the expert toggle is a switch among the settings")
        // The gui's left column: what the footage is, then how it is processed.
        val left = dialog.substringAfter("val left: @Composable ColumnScope.() -> Unit").substringBefore("val right:")
        val order = listOf("infoId = \"scene\"", "infoId = \"camera\"", "infoId = \"clean\"").map { left.indexOf(it) }
        assertTrue(order.all { it >= 0 } && order == order.sorted(), "scene type, camera motion, then the clean method: $order")
    }
}
