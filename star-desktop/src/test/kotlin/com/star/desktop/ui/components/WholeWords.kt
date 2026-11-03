package com.star.desktop.ui.components

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.width
import androidx.compose.runtime.Composable
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.runComposeUiTest
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.unit.Dp
import com.star.desktop.i18n.Strings
import com.star.desktop.ui.theme.StarTheme

/** The languages the whole-words checks run in: English, and German for its long compound words. */
internal val WHOLE_WORD_LANGUAGES = listOf("en", "de")

/**
 * Lays [content] out in a box [width] wide and returns a description of every Text in it whose lines break inside a word, or that is cut
 * off by its cell without an ellipsis. Empty means every line break lands on whitespace (or a hyphen) and nothing is clipped silently.
 * Ellipsized lines are not breaks: they show their cut, and the tooltip rule is tested on its own.
 */
@OptIn(ExperimentalTestApi::class, ExperimentalComposeUiApi::class)
internal fun wholeWordProblems(width: @Composable () -> Dp, content: @Composable () -> Unit): List<String> {
    val problems = ArrayList<String>()
    runComposeUiTest {
        setContent { StarTheme { Box(Modifier.width(width())) { content() } } }
        waitForIdle()
        val nodes = onAllNodes(SemanticsMatcher.keyIsDefined(SemanticsActions.GetTextLayoutResult), useUnmergedTree = true).fetchSemanticsNodes()
        for (node in nodes) {
            val results = ArrayList<TextLayoutResult>()
            node.config.getOrNull(SemanticsActions.GetTextLayoutResult)?.action?.invoke(results)
            val layout = results.firstOrNull() ?: continue
            problems += problemsIn(layout)
        }
    }
    return problems
}

private fun problemsIn(layout: TextLayoutResult): List<String> {
    val text = layout.layoutInput.text.text
    val out = ArrayList<String>()
    for (line in 0 until layout.lineCount) {
        if (layout.isLineEllipsized(line)) continue
        val end = layout.getLineEnd(line, visibleEnd = false)
        if (end in 1 until text.length) {
            val before = text[end - 1]
            val after = text[end]
            if (!(before.isWhitespace() || after.isWhitespace() || before == '-' || before == '\n')) {
                out += "\"$text\" breaks inside a word at line ${line + 1}: \"${text.substring(layout.getLineStart(line), end)}\" | \"${text.substring(end).take(12)}\""
            }
        }
    }
    // One line, wider than its cell, and not ellipsized: the end is clipped away.
    // (The line's own extent, not didOverflowWidth, which is also set for a cell that is only a rounding error narrower.)
    for (line in 0 until layout.lineCount) {
        val extent = layout.getLineRight(line) - layout.getLineLeft(line)
        if (!layout.isLineEllipsized(line) && extent > layout.size.width + 1f) out += "\"$text\" is clipped by its cell (${extent}px of text in ${layout.size.width}px)"
    }
    return out
}

/** Runs [check] once per language in [WHOLE_WORD_LANGUAGES] and collects the problems, each tagged with its language. */
internal fun wholeWordProblemsInEachLanguage(width: Dp, content: @Composable () -> Unit): List<String> = wholeWordProblemsInEachLanguage({ width }, content)

internal fun wholeWordProblemsInEachLanguage(width: @Composable () -> Dp, content: @Composable () -> Unit): List<String> {
    val all = ArrayList<String>()
    try {
        for (code in WHOLE_WORD_LANGUAGES) {
            Strings.setOverride(code)
            all += wholeWordProblems(width, content).map { "[$code] $it" }
        }
    } finally {
        Strings.setOverride(null)
    }
    return all
}
