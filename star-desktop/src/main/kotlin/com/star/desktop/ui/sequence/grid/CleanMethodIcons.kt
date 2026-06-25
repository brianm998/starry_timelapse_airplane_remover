package com.star.desktop.ui.sequence.grid

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.star.proto.CleanMethod

/**
 * The three clean-method glyphs (macOS `AutoIcon`/`SelectiveIcon`/`AutoSelectiveIcon`, defined in
 * FilmstripImageView). SF Symbol `sparkle` is replaced with a Unicode four-point star; the selective
 * half-moon is drawn on a Canvas. Used in the grid header and right panel.
 */
@Composable
fun CleanMethodIcon(method: CleanMethod, color: Color, sizeDp: Dp = 8.dp) {
    when (method) {
        CleanMethod.CLEAN_AUTOMATIC_TRUE -> AutoSelectiveIcon(color, sizeDp)
        CleanMethod.CLEAN_AUTOMATIC -> AutoIcon(color, sizeDp)
        else -> SelectiveIcon(color, sizeDp)
    }
}

@Composable
fun AutoIcon(color: Color, sizeDp: Dp = 8.dp) {
    Text("✦", color = color, fontSize = sizeDp.value.sp)
}

/** A circle outline whose left half is filled (macOS SelectiveIcon). */
@Composable
fun SelectiveIcon(color: Color, sizeDp: Dp = 8.dp, modifier: Modifier = Modifier) {
    Canvas(modifier.size(sizeDp)) {
        val d = size.minDimension
        drawArc(color = color, startAngle = 90f, sweepAngle = 180f, useCenter = true, topLeft = Offset.Zero, size = Size(d, d))
        drawCircle(color = color, radius = d / 2f - 0.5.dp.toPx(), center = Offset(d / 2f, d / 2f), style = Stroke(width = 1.dp.toPx()))
    }
}

/** Sparkle with a small selective half-moon at the top-right (macOS AutoSelectiveIcon). */
@Composable
fun AutoSelectiveIcon(color: Color, sizeDp: Dp = 8.dp) {
    Box(Modifier.size(sizeDp), contentAlignment = Alignment.Center) {
        Text("✦", color = color, fontSize = sizeDp.value.sp)
        SelectiveIcon(color.copy(alpha = 0.6f), (sizeDp.value * 0.6f).dp, Modifier.align(Alignment.TopEnd))
    }
}
