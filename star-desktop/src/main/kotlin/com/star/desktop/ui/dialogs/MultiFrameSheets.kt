package com.star.desktop.ui.dialogs

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.star.desktop.domain.MultiFrameRange
import com.star.desktop.ui.sequence.SequenceViewModel
import com.star.desktop.ui.theme.StarColors
import com.star.desktop.ui.theme.StarShapes
import com.star.desktop.i18n.localized

/**
 * An action a sheet can apply: keep/remove, optionally to outliers *overlapping* those in the area. [summaryPrefix] is the catalogue
 * entry the sentence saying what it will do to which frames is built from (`ui.overlap.paint`, `ui.area.keep_overlaps`, …).
 */
private data class MultiAction(
    val label: String, val shouldRemove: Boolean, val overlapping: Boolean, val accent: Color, val summaryPrefix: String,
)

/** Multi-choice sheet (macOS `MultiChoiceSheetView`): propagate a decision to overlapping outliers. */
@Composable
fun MultiChoiceSheet(vm: SequenceViewModel, target: SequenceViewModel.MultiChoiceTarget) {
    val actions = listOf(
        MultiAction(localized("multi_paint.remove"), true, false, StarColors.red, "ui.overlap.paint"),
        MultiAction(localized("multi_paint.keep"), false, false, StarColors.green, "ui.overlap.clear"),
    )
    MultiFrameSheet(
        title = localized("ui.change_overlapping_outliers_in_other_frames"),
        actions = actions,
        defaultIndex = if (target.currentlyRemoves) 1 else 0,   // pre-select the opposite of the clicked group
        current = vm.currentIndex.value,
        frameCount = vm.frameCount,
        actionButtonLabel = { localized(if (it.shouldRemove) "ui.remove" else "ui.keep") },
        onCancel = vm::dismissMultiSheets,
        onApply = { a, range, n, _ -> vm.applyMultiChoice(a.shouldRemove, range, n) },
    )
}

/** Multi-select sheet (macOS `MultiSelectSheetView`): apply a decision to a rectangular area. */
@Composable
fun MultiSelectSheet(vm: SequenceViewModel, @Suppress("UNUSED_PARAMETER") sel: SequenceViewModel.RectSelection) {
    val actions = listOf(
        MultiAction(localized("multi_removal.remove"), true, false, StarColors.red, "ui.area.remove"),
        MultiAction(localized("multi_removal.keep"), false, false, StarColors.green, "ui.area.keep"),
        MultiAction(localized("multi_removal.removeOverlaps"), true, true, StarColors.red, "ui.area.remove_overlaps"),
        MultiAction(localized("multi_removal.keepOverlaps"), false, true, StarColors.green, "ui.area.keep_overlaps"),
    )
    MultiFrameSheet(
        title = localized("ui.change_outliers_in_the_selected_area_across"),
        actions = actions,
        defaultIndex = 0,
        current = vm.currentIndex.value,
        frameCount = vm.frameCount,
        actionButtonLabel = { localized("ui.modify") },
        onCancel = vm::dismissMultiSheets,
        onApply = { a, range, n, includingTrash -> vm.applyMultiSelect(a.shouldRemove, a.overlapping, range, n, includingTrash) },
        trashInitially = vm.showTrash.value,
    )
}

@OptIn(androidx.compose.foundation.layout.ExperimentalLayoutApi::class)
@Composable
private fun MultiFrameSheet(
    title: String,
    actions: List<MultiAction>,
    defaultIndex: Int,
    /** The frame being looked at, and how many there are: the sentence under the choices counts the frames each one reaches. */
    current: Int,
    frameCount: Int,
    actionButtonLabel: (MultiAction) -> String,
    onCancel: () -> Unit,
    onApply: (MultiAction, MultiFrameRange, Int, Boolean) -> Unit,
    /** null: no trash option (the multi-choice sheet acts on a chosen group); else whether it starts on, which is whether the trash is showing. */
    trashInitially: Boolean? = null,
) {
    var actionIdx by remember { mutableStateOf(defaultIndex.coerceIn(0, actions.size - 1)) }
    var range by remember { mutableStateOf(MultiFrameRange.ALL) }
    var nText by remember { mutableStateOf("5") }
    var includingTrash by remember { mutableStateOf(trashInitially ?: false) }
    val action = actions[actionIdx]

    Box(Modifier.fillMaxSize().background(StarColors.scrim).clickable(onClick = onCancel), contentAlignment = Alignment.Center) {
        Column(
            Modifier
                .widthIn(min = 340.dp, max = 460.dp)
                .clip(StarShapes.card)
                .background(StarColors.prefsCard)
                .clickable(enabled = false) {}
                .padding(24.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text(title, color = StarColors.textPrimary, fontWeight = FontWeight.SemiBold, fontSize = 15.sp)
            androidx.compose.foundation.layout.FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                actions.forEachIndexed { i, a ->
                    Pill(a.label, selected = i == actionIdx, accent = a.accent) { actionIdx = i }
                }
            }
            Text(localized("ui.what_frames_should_we_modify"), color = StarColors.textSecondary, fontSize = 12.sp)
            MultiFrameRange.entries.forEach { r ->
                RadioRow(r.label, selected = r == range) { range = r }
            }
            // What the action will do, in words (macOS shows this under the choices; a count the user types has no sentence).
            range.summary(action.summaryPrefix, current, frameCount)?.let {
                Text(it, color = StarColors.textSecondary, fontSize = 12.sp)
            }
            if (range.needsCount) {
                OutlinedTextField(
                    value = nText,
                    onValueChange = { nText = it.filter(Char::isDigit) },
                    label = { Text(localized("ui.number_of_frames")) },
                    singleLine = true,
                    modifier = Modifier.width(180.dp),
                )
            }
            if (trashInitially != null) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    androidx.compose.material3.Switch(checked = includingTrash, onCheckedChange = { includingTrash = it })
                    Text(localized("ui.trash"), color = StarColors.textPrimary, fontSize = 12.sp)
                }
            }
            Row(Modifier.fillMaxWidth().padding(top = 8.dp), horizontalArrangement = Arrangement.spacedBy(10.dp, Alignment.End)) {
                OutlinedButton(onClick = onCancel) { Text(localized("ui.cancel")) }
                Button(
                    onClick = { onApply(action, range, nText.toIntOrNull() ?: 5, includingTrash) },
                    colors = ButtonDefaults.buttonColors(containerColor = StarColors.accent),
                ) { Text(actionButtonLabel(action)) }
            }
        }
    }
}

@Composable
private fun Pill(label: String, selected: Boolean, accent: Color, onClick: () -> Unit) {
    Text(
        label,
        color = if (selected) Color.White else StarColors.textPrimary,
        fontSize = 12.sp,
        modifier = Modifier
            .clip(RoundedCornerShape(5.dp))
            .background(if (selected) accent else StarColors.cellDefault)
            .clickable(onClick = onClick)
            .padding(horizontal = 14.dp, vertical = 6.dp),
    )
}

@Composable
private fun RadioRow(label: String, selected: Boolean, onClick: () -> Unit) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp),
        modifier = Modifier.fillMaxWidth().clickable(onClick = onClick).padding(vertical = 2.dp)) {
        Text(if (selected) "◉" else "○", color = if (selected) StarColors.accent else StarColors.textSecondary, fontSize = 13.sp)
        Text(label, color = StarColors.textPrimary, fontSize = 12.sp)
    }
}
