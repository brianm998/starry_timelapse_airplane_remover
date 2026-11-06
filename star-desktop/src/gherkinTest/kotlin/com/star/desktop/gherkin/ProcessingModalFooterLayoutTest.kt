package com.star.desktop.gherkin

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.width
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.SemanticsNodeInteraction
import androidx.compose.ui.test.getBoundsInRoot
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.runDesktopComposeUiTest
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.star.desktop.i18n.localized
import com.star.desktop.ui.dialogs.PREVIEW_BUTTON_MIN_WIDTH
import com.star.desktop.ui.dialogs.PreviewFooter
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * The Processing Frames dialog's footer at the dialog's narrowest: the card is 480dp wide at least, with 20dp of padding on it and 20dp more on the
 * footer row, so 400dp is what the Stop chip and the Preview side share. The Preview button used to be squeezed to a sliver there, its label
 * wrapping ("Previe" over "w"), with the help text touching it. Layout is checked in dp with a tolerance, not in pixels, so it does not depend on
 * the font.
 *
 *     ./gradlew gherkinTest --tests '*ProcessingModalFooterLayoutTest*'
 */
@OptIn(ExperimentalTestApi::class)
class ProcessingModalFooterLayoutTest {
    private val tolerance = 1.dp
    /** The longest `ui.preview` in the catalogue (pt-BR), which is the widest label the button has to hold. */
    private val longestLabel = "Pré-visualização"
    private val labels = listOf(localized("ui.preview"), longestLabel)

    /** The footer row's room: the Stop chip (about this wide in English) and its 12dp gap come off the 400dp. */
    private fun withFooter(label: String, check: androidx.compose.ui.test.ComposeUiTest.() -> Unit) = runDesktopComposeUiTest(width = 500, height = 200) {
        setContent {
            Row(Modifier.width(400.dp), horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
                Box(Modifier.width(90.dp).height(24.dp))
                PreviewFooter({}, Modifier.weight(1f), label)
            }
        }
        waitForIdle()
        check()
    }

    private fun androidx.compose.ui.test.ComposeUiTest.bounds(tag: String): androidx.compose.ui.unit.DpRect =
        onNodeWithTag(tag, useUnmergedTree = true).getBoundsInRoot()

    private fun androidx.compose.ui.test.ComposeUiTest.lineCount(tag: String): Int {
        val node: SemanticsNodeInteraction = onNodeWithTag(tag, useUnmergedTree = true)
        val results = mutableListOf<TextLayoutResult>()
        node.fetchSemanticsNode().config.getOrNull(SemanticsActions.GetTextLayoutResult)?.action?.invoke(results)
        return results.single().lineCount
    }

    @Test fun previewLabelIsOneLine() {
        for (label in labels) withFooter(label) {
            assertEquals(1, lineCount("processing.previewLabel"), "the \"$label\" label wrapped")
        }
    }

    @Test fun previewButtonIsWideEnough() {
        for (label in labels) withFooter(label) {
            val button = bounds("processing.previewButton")
            val text = bounds("processing.previewLabel")
            val width: Dp = button.right - button.left
            assertTrue(width + tolerance >= PREVIEW_BUTTON_MIN_WIDTH, "\"$label\": the button is $width wide, under $PREVIEW_BUTTON_MIN_WIDTH")
            // The label with the button's 20dp of padding on each side: the button is never narrower than what it holds.
            assertTrue(width + tolerance >= (text.right - text.left) + 40.dp, "\"$label\": the button is $width wide for a label ${text.right - text.left} wide")
        }
    }

    @Test fun helpTextIsClearOfButton() {
        for (label in labels) withFooter(label) {
            val help = bounds("processing.previewHelp")
            val button = bounds("processing.previewButton")
            assertTrue(button.left - help.right + tolerance >= 16.dp, "\"$label\": ${button.left - help.right} between the help text and the button")
            // The help text is what gives way: it ends up inside the room, not past the row's 400dp, and the button is at its right end.
            assertTrue(help.left >= 90.dp + 12.dp - tolerance, "\"$label\": the help text starts at ${help.left}, over the Stop chip")
            assertTrue(button.right <= 400.dp + tolerance, "\"$label\": the button ends at ${button.right}, past the row")
        }
    }
}
