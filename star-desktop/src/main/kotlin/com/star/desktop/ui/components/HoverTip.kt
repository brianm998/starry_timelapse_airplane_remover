package com.star.desktop.ui.components

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.TooltipArea
import androidx.compose.foundation.TooltipPlacement
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.DpOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.star.desktop.ui.theme.StarColors

/** Hover popup with a short help text, shown after the pointer rests on [content] (macOS `.help`). */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun HoverTip(text: String, content: @Composable () -> Unit) {
    TooltipArea(
        tooltip = {
            Surface(shape = RoundedCornerShape(4.dp), color = StarColors.prefsCard, shadowElevation = 4.dp) {
                Text(text, color = StarColors.white, fontSize = 11.sp, modifier = Modifier.widthIn(max = 260.dp).padding(8.dp))
            }
        },
        delayMillis = 400,
        tooltipPlacement = TooltipPlacement.CursorPoint(offset = DpOffset(0.dp, 16.dp)),
        content = content,
    )
}
