package com.star.desktop.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.star.desktop.ui.theme.StarColors

/**
 * The thin gutter shown in place of a collapsed side panel (macOS LeftPanel/RightPanel closedView):
 * just an expand chevron pinned to the bottom. [pointLeft] picks the double-chevron direction —
 * the chevron points toward the screen edge the panel tucks into.
 */
@Composable
fun CollapsedPanelRail(onExpand: () -> Unit, pointLeft: Boolean, modifier: Modifier = Modifier) {
    Column(
        modifier = modifier
            .width(28.dp)
            .fillMaxHeight()
            .background(StarColors.sidePanel)
            .padding(6.dp),
        verticalArrangement = Arrangement.Bottom,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        PanelChevron(if (pointLeft) "«" else "»", onExpand)
    }
}

/** A plain gray double-chevron toggle (macOS `chevron.left.2` / `chevron.right.2`, PlainButtonStyle). */
@Composable
fun PanelChevron(glyph: String, onClick: () -> Unit, modifier: Modifier = Modifier) {
    Box(
        modifier = modifier.clickable(onClick = onClick).padding(4.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(glyph, color = StarColors.gray, fontSize = 16.sp)
    }
}
