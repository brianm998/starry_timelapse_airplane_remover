package com.star.desktop.ui.components

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.star.desktop.ui.theme.StarColors

/** The small chevron under a list that expands it to show everything, and folds it back (macOS `ExpandUpButton`). */
@Composable
fun ExpandToggle(expanded: Boolean, onToggle: () -> Unit, modifier: Modifier = Modifier) {
    Text(
        if (expanded) "⌄" else "⌃",
        color = StarColors.textSecondary,
        fontSize = 16.sp,
        modifier = modifier.clickable(onClick = onToggle).padding(horizontal = 6.dp),
    )
}
