package com.star.desktop.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.selection.selectable
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import com.star.desktop.ui.theme.StarColors
import com.star.desktop.ui.theme.StarShapes
import com.star.desktop.ui.theme.StarType

/** Unselected option text, dark on the light-gray track; the pickers that do not ask for another colour use it. */
internal val STAR_PICKER_DEFAULT_UNSELECTED_TEXT = Color(0.12f, 0.12f, 0.12f)

/** The text colour of one option: grey when it cannot be chosen, black on the selected pill, else [unselectedText]. */
internal fun starPickerTextColor(selected: Boolean, usable: Boolean, unselectedText: Color = STAR_PICKER_DEFAULT_UNSELECTED_TEXT): Color =
    if (!usable) Color.Gray else if (selected) Color.Black else unselectedText

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
    /** False greys out and locks the whole control (macOS `.disabled`, e.g. while a video plays). */
    enabled: Boolean = true,
    /** Whether one option can be chosen: a mode the frame has no image for is greyed out and does nothing. */
    isEnabled: (T) -> Boolean = { true },
    /** The id a UI test finds an option by (`gherkin/ui/ids.json`), for those that have one; the option also says whether it is the selected one, as a radio button does. */
    tag: (T) -> String? = { null },
    /** The text colour of the options that are not selected (the selected one is always black on its white pill). */
    unselectedText: Color = STAR_PICKER_DEFAULT_UNSELECTED_TEXT,
) {
    Row(
        modifier.alpha(if (enabled) 1f else 0.5f).clip(StarShapes.picker).background(StarColors.pickerTrack).padding(2.dp),
        horizontalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        options.forEach { opt ->
            val sel = opt == selected
            val usable = enabled && isEnabled(opt)
            Box(
                Modifier
                    .clip(StarShapes.picker)
                    .background(if (sel) StarColors.white else Color.Transparent)
                    .selectable(selected = sel, enabled = usable, role = Role.RadioButton) { onSelect(opt) }
                    .then(tag(opt)?.let { Modifier.testTag(it) } ?: Modifier)
                    .padding(horizontal = 10.dp, vertical = 4.dp),
            ) {
                Text(
                    label(opt),
                    color = starPickerTextColor(selected = sel, usable = isEnabled(opt), unselectedText = unselectedText),
                    style = StarType.body,
                )
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
                Text(label(opt), color = if (sel) Color.Black else STAR_PICKER_DEFAULT_UNSELECTED_TEXT, style = StarType.body)
            }
        }
    }
}
