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

/** Multi-choice sheet (macOS `MultiChoiceSheetView`): propagate a decision to overlapping outliers. */
@Composable
fun MultiChoiceSheet(vm: SequenceViewModel, target: SequenceViewModel.MultiChoiceTarget) {
    MultiFrameSheet(
        title = "Change overlapping outliers in other frames to:",
        actionLabel = { if (it) "Remove" else "Keep" },
        defaultRemove = !target.currentlyRemoves,           // pre-select the opposite of the clicked group
        onCancel = vm::dismissMultiSheets,
        onApply = { remove, range, n -> vm.applyMultiChoice(remove, range, n) },
    )
}

/** Multi-select sheet (macOS `MultiSelectSheetView`): apply a decision to a rectangular area. */
@Composable
fun MultiSelectSheet(vm: SequenceViewModel, @Suppress("UNUSED_PARAMETER") sel: SequenceViewModel.RectSelection) {
    MultiFrameSheet(
        title = "Change outliers in the selected area across frames:",
        actionLabel = { "Modify" },
        defaultRemove = true,
        onCancel = vm::dismissMultiSheets,
        onApply = { remove, range, n -> vm.applyMultiSelect(remove, range, n) },
    )
}

@Composable
private fun MultiFrameSheet(
    title: String,
    actionLabel: (Boolean) -> String,
    defaultRemove: Boolean,
    onCancel: () -> Unit,
    onApply: (Boolean, MultiFrameRange, Int) -> Unit,
) {
    var remove by remember { mutableStateOf(defaultRemove) }
    var range by remember { mutableStateOf(MultiFrameRange.ALL) }
    var nText by remember { mutableStateOf("5") }

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
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Pill("Remove", remove, StarColors.red) { remove = true }
                Pill("Keep", !remove, StarColors.green) { remove = false }
            }
            Text("What frames should we modify?", color = StarColors.textSecondary, fontSize = 12.sp)
            MultiFrameRange.entries.forEach { r ->
                RadioRow(r.label, selected = r == range) { range = r }
            }
            if (range.needsCount) {
                OutlinedTextField(
                    value = nText,
                    onValueChange = { nText = it.filter(Char::isDigit) },
                    label = { Text("Number of frames") },
                    singleLine = true,
                    modifier = Modifier.width(180.dp),
                )
            }
            Row(Modifier.fillMaxWidth().padding(top = 8.dp), horizontalArrangement = Arrangement.spacedBy(10.dp, Alignment.End)) {
                OutlinedButton(onClick = onCancel) { Text("Cancel") }
                Button(
                    onClick = { onApply(remove, range, nText.toIntOrNull() ?: 5) },
                    colors = ButtonDefaults.buttonColors(containerColor = StarColors.accent),
                ) { Text(actionLabel(remove)) }
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
