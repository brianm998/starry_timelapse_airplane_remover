package com.star.desktop.ui.dialogs

import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextReplacement
import androidx.compose.ui.test.runDesktopComposeUiTest
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.star.desktop.i18n.Strings
import com.star.proto.KeypointDivisorAdvice
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

@OptIn(ExperimentalTestApi::class)
class SpeedSharpnessDialogTest {
    @BeforeTest fun english() = Strings.setOverride("en")
    @AfterTest fun systemLanguage() = Strings.setOverride(null)

    private fun advice(reduce: Boolean) = KeypointDivisorAdvice.newBuilder()
        .setAvailable(true).setReduceRecommended(reduce).setRecommendedDivisor(if (reduce) 1.5 else 1.0)
        .setImagePixels(42_400_000).setThresholdPixels(12_900_000).setFullResolutionConcurrency(10).setFrameConcurrency(36)
        .setPhysicalMemoryBytes(128L * 1024 * 1024 * 1024).build()

    @Test fun speedSharpnessModalOpensAndCloses() = runDesktopComposeUiTest {
        var open by mutableStateOf(true)
        var updated: Double? = null
        setContent {
            if (open) SpeedSharpnessDialog(initial = 4.0, advice = advice(reduce = true), onCancel = { open = false }, onUpdate = { updated = it; open = false })
        }
        // The whole of the old section: presets, the recommended badge, the custom field and the too-high warning (4 is the warning's threshold).
        for (tag in listOf("startup.speed.preset.1", "startup.speed.preset.1.5", "startup.speed.preset.2", "startup.speed.recommended",
                           "startup.speed.custom", "startup.speed.toohigh", "startup.speed.cancel", "startup.speed.update")) {
            onNodeWithTag(tag, useUnmergedTree = true).assertIsDisplayed()
        }
        onNodeWithTag("startup.speed.update").performClick()
        waitForIdle()
        assertEquals(4.0, updated)
        onNodeWithTag("startup.speed.modal").assertDoesNotExist()
    }

    @Test fun cancelIsLeftOfUpdateAndBothClose() = runDesktopComposeUiTest {
        var open by mutableStateOf(true)
        var cancelled = 0
        var updated = mutableListOf<Double>()
        setContent {
            if (open) SpeedSharpnessDialog(initial = 1.0, advice = null, onCancel = { cancelled++; open = false }, onUpdate = { updated += it; open = false })
        }
        val cancel = onNodeWithTag("startup.speed.cancel").fetchSemanticsNode().boundsInRoot
        val update = onNodeWithTag("startup.speed.update").fetchSemanticsNode().boundsInRoot
        assertTrue(cancel.right <= update.left, "Cancel is on the left: $cancel vs $update")

        // Cancel closes without handing a value over, even after the draft was edited.
        onNodeWithTag("startup.speed.preset.2").performClick()
        onNodeWithTag("startup.speed.cancel").performClick()
        waitForIdle()
        onNodeWithTag("startup.speed.modal").assertDoesNotExist()
        assertEquals(1, cancelled)
        assertTrue(updated.isEmpty())

        // Update after typing a custom value hands that value over.
        open = true
        waitForIdle()
        onNodeWithTag("startup.speed.custom").performTextReplacement("3.2")
        onNodeWithTag("startup.speed.update").performClick()
        waitForIdle()
        onNodeWithTag("startup.speed.modal").assertDoesNotExist()
        assertEquals(listOf(3.2), updated)
    }
}
