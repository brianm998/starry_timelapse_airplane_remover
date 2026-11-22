package com.star.desktop.ui.dialogs

import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.runComposeUiTest
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.width
import androidx.compose.foundation.layout.size
import androidx.compose.ui.test.getBoundsInRoot
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/** The "Processing complete" card: full-size pictures in a wide window, nothing spilling out of the card in a narrow one. */
@OptIn(ExperimentalTestApi::class, ExperimentalComposeUiApi::class)
class PostProcessingPromptLayoutTest {
    private fun bitmap() = ImageBitmap(600, 400)

    @Test
    fun picturesAreFullSizeInAWideWindow() = runComposeUiTest {
        setContent {
            androidx.compose.foundation.layout.Box(androidx.compose.ui.Modifier.size(1200.dp, 900.dp)) {
                PostProcessingPromptCard(bitmap() to bitmap(), onDismiss = {}, onPreview = {}, onYes = {})
            }
        }
        val card = onNodeWithTag("prompt.card", useUnmergedTree = true).getBoundsInRoot()
        for (tag in listOf("prompt.post.before", "prompt.post.after")) {
            val b = onNodeWithTag(tag, useUnmergedTree = true).getBoundsInRoot()
            assertEquals(240f, b.width.value, 0.6f, "$tag width")
            assertTrue(b.left >= card.left && b.right <= card.right, "$tag inside the card")
        }
    }

    @Test
    fun nothingSpillsOutOfTheCardWhenNarrow() = runComposeUiTest {
        setContent {
            androidx.compose.foundation.layout.Box(androidx.compose.ui.Modifier.size(500.dp, 900.dp)) {
                PostProcessingPromptCard(bitmap() to bitmap(), onDismiss = {}, onPreview = {}, onYes = {})
            }
        }
        val card = onNodeWithTag("prompt.card", useUnmergedTree = true).getBoundsInRoot()
        assertTrue(card.width.value <= 500.5f, "card ${card.width} fits the window")
        for (tag in listOf("prompt.post.before", "prompt.post.after", "prompt.post.cancel", "prompt.post.preview", "prompt.post.yes")) {
            val b = onNodeWithTag(tag, useUnmergedTree = true).getBoundsInRoot()
            assertTrue(b.left >= card.left - 0.5.dp && b.right <= card.right + 0.5.dp, "$tag $b inside the card $card")
        }
    }
}
