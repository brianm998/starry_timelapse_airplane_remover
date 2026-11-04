package com.star.desktop.ui.components

import androidx.compose.material3.LocalTextStyle
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp

/**
 * The width of the widest single word in [texts] at [fontSize]: the least a cell for them can be before a line has to break inside a word.
 * Cells whose text wraps at spaces are given at least this much, so a long translation wraps at its spaces and never in the middle of a word.
 * [wholeText] measures each text whole instead (one line, no wrapping), for cells that must not wrap at all.
 */
@Composable
fun widestWord(texts: List<String>, fontSize: TextUnit, fontWeight: FontWeight? = null, wholeText: Boolean = false): Dp {
    val measurer = rememberTextMeasurer()
    val density = LocalDensity.current
    val base = LocalTextStyle.current
    return remember(texts, fontSize, fontWeight, wholeText, density.density, density.fontScale, base) {
        val style = base.copy(fontSize = fontSize, fontWeight = fontWeight ?: base.fontWeight)
        val words = if (wholeText) texts else texts.flatMap { it.split(' ', '\n', '\t') }
        val px = words.filter { it.isNotEmpty() }.maxOfOrNull { measurer.measure(it, style, softWrap = false, maxLines = 1).size.width } ?: 0
        // A pixel of slack: the measured width is rounded up, but a cell of exactly that width has broken a line before now.
        with(density) { px.toDp() } + 1.dp
    }
}
