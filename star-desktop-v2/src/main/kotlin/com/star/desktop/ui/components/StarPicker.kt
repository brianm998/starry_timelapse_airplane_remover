package com.star.desktop.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import com.star.desktop.ui.theme.StarColors
import com.star.desktop.ui.theme.StarShapes
import com.star.desktop.ui.theme.StarType

private val UNSELECTED_TEXT = Color(0.12f, 0.12f, 0.12f)   // dark, on the light-gray track

/**
 * Horizontal segmented control (macOS `StarPicker`): a light-gray track with a white pill on the
 * selected option. Single source for the mode/view-mode/etc. pickers.
 */
@Composable
fun <T> StarPicker(
    options: List<T>,
    selected: T,
    label: (T) -> String,
    onSelect: (T) -> Unit,
    modifier: Modifier = Modifier,
) {
    Row(
        modifier.clip(StarShapes.picker).background(StarColors.pickerTrack).padding(2.dp),
        horizontalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        options.forEach { opt ->
            val sel = opt == selected
            Box(
                Modifier
                    .clip(StarShapes.picker)
                    .background(if (sel) StarColors.white else Color.Transparent)
                    .clickable { onSelect(opt) }
                    .padding(horizontal = 10.dp, vertical = 4.dp),
            ) {
                Text(label(opt), color = if (sel) Color.Black else UNSELECTED_TEXT, style = StarType.body)
            }
        }
    }
}

/**
 * Vertical variant (macOS `VerticalStarPicker`): selected uses a translucent-white pill. For lists
 * with long labels (the grid "Show" picker, clean-method / fast-skip rows, multi-frame ranges).
 */
@Composable
fun <T> VerticalStarPicker(
    options: List<T>,
    selected: T,
    label: (T) -> String,
    onSelect: (T) -> Unit,
    modifier: Modifier = Modifier,
) {
    Column(
        modifier.clip(StarShapes.picker).background(StarColors.pickerTrack).padding(2.dp),
        verticalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        options.forEach { opt ->
            val sel = opt == selected
            Box(
                Modifier
                    .fillMaxWidth()
                    .clip(StarShapes.picker)
                    .background(if (sel) StarColors.white else Color.Transparent)
                    .clickable { onSelect(opt) }
                    .padding(horizontal = 8.dp, vertical = 4.dp),
            ) {
                Text(label(opt), color = if (sel) Color.Black else UNSELECTED_TEXT, style = StarType.body)
            }
        }
    }
}
