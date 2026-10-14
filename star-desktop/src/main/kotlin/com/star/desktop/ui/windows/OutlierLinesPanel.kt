package com.star.desktop.ui.windows

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.star.desktop.domain.HoughLines
import com.star.desktop.i18n.localized
import com.star.desktop.ui.sequence.SequenceViewModel
import com.star.desktop.ui.theme.StarColors
import com.star.proto.HoughLineFinderArg
import com.star.proto.LineCandidate
import com.star.proto.OutlierGroup
import kotlinx.coroutines.launch

/**
 * The part of the outlier window under the table (macOS `OutlierWindowView`'s bottom row): for one selected group, the lines the Hough
 * finder proposes for it, and picking one makes it the group's line (drawn on the frame); beside them, the finder's arguments, which
 * give new lines when they change.
 */
@Composable
fun OutlierLinesPanel(vm: SequenceViewModel, windowFrame: Int, selection: Set<Int>, groups: List<OutlierGroup>) {
    // Bumped when an argument changes, so the lines are worked out again.
    var argsVersion by remember { mutableIntStateOf(0) }
    Row(Modifier.fillMaxWidth().height(250.dp).padding(top = 8.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        Column(Modifier.weight(1f).fillMaxHeight()) {
            when (selection.size) {
                0 -> Text(localized("ui.select_some_outliers"), color = StarColors.textSecondary, fontSize = 12.sp)
                1 -> {
                    val id = selection.first()
                    LinesTable(vm, windowFrame, id, groups.firstOrNull { it.id == id }, argsVersion)
                }
                else -> Text(localized("ui.n_outliers_selected", selection.size), color = StarColors.textSecondary, fontSize = 12.sp)
            }
        }
        FinderArgs(vm) { argsVersion++ }
    }
}

private val COLUMNS = listOf(
    HoughLines.Column.INTENSITY to "ui.intensity_score",
    HoughLines.Column.PIXEL to "ui.pixel_score",
    HoughLines.Column.THETA to "ui.theta",
    HoughLines.Column.RHO to "ui.rho",
    HoughLines.Column.VOTES to "ui.votes",
    HoughLines.Column.BORDER to "ui.border",
)
private val LINE_CELL = 90.dp

@Composable
private fun LinesTable(vm: SequenceViewModel, frameIndex: Int, groupId: Int, group: OutlierGroup?, argsVersion: Int) {
    var candidates by remember(frameIndex, groupId, argsVersion) { mutableStateOf<List<LineCandidate>?>(null) }
    LaunchedEffect(frameIndex, groupId, argsVersion) {
        candidates = null
        candidates = vm.lineCandidates(frameIndex, groupId)
    }
    var sort by remember { mutableStateOf(HoughLines.defaultSort) }
    val shown = remember(candidates, sort) { candidates?.let { HoughLines.sorted(it, sort) } }

    Text(localized("ui.hough_lines_for_the_selected_outlier"), color = StarColors.textPrimary, fontWeight = FontWeight.SemiBold, fontSize = 12.sp)
    Text(
        localized("ui.select_a_line_to_see_it_on_the_main_window") + " " + localized("ui.or_update_the_line_parameters_to_see_any"),
        color = StarColors.textSecondary, fontSize = 11.sp,
    )
    if (shown == null) {
        Text(localized("ui.loading_outliers_for_this_frame"), color = StarColors.textSecondary, fontSize = 11.sp, modifier = Modifier.padding(top = 6.dp))
        return
    }
    Text(localized("ui.info_about_n_lines", shown.size), color = StarColors.textPrimary, fontSize = 11.sp, modifier = Modifier.padding(vertical = 4.dp))
    Row(Modifier.background(StarColors.sidePanel).padding(vertical = 4.dp)) {
        for ((column, key) in COLUMNS) {
            val arrow = if (sort.column == column) (if (sort.ascending) " ▲" else " ▼") else ""
            Text(
                localized(key) + arrow, color = StarColors.textSecondary, fontSize = 11.sp, fontWeight = FontWeight.SemiBold, maxLines = 1,
                modifier = Modifier.width(LINE_CELL).clickable { sort = HoughLines.clicked(sort, column) }.padding(horizontal = 6.dp),
            )
        }
    }
    LazyColumn(Modifier.fillMaxWidth()) {
        items(shown) { c ->
            val current = HoughLines.isLine(c, if (group?.hasLine() == true) group.line else null)
            Row(
                Modifier
                    .background(if (current) StarColors.cellSelected else StarColors.appBackground)
                    .clickable { vm.setOutlierLine(frameIndex, groupId, c) }
                    .padding(vertical = 3.dp),
            ) {
                LineCell(HoughLines.format(c.intensityScore))
                LineCell(HoughLines.format(c.pixelScore))
                LineCell(HoughLines.format(c.line.theta))
                LineCell(HoughLines.format(c.line.rho))
                LineCell("${c.line.votes}")
                LineCell("${c.border}")
            }
        }
    }
}

@Composable
private fun LineCell(text: String) {
    Text(text, color = StarColors.textPrimary, fontSize = 11.sp, maxLines = 1, modifier = Modifier.width(LINE_CELL).padding(horizontal = 6.dp))
}

/** The Hough finder's arguments (macOS `ArgableView`): a name, an editable value, and what it does. Return, or leaving the field, applies it. */
@Composable
private fun FinderArgs(vm: SequenceViewModel, onChanged: () -> Unit) {
    var args by remember { mutableStateOf<List<HoughLineFinderArg>?>(null) }
    LaunchedEffect(Unit) { args = vm.houghArgs().ifEmpty { null } }
    val scope = rememberCoroutineScope()
    Column(Modifier.width(320.dp).fillMaxHeight().verticalScroll(rememberScrollState())) {
        Text(localized("ui.hough_line_arguments"), color = StarColors.textPrimary, fontWeight = FontWeight.SemiBold, fontSize = 12.sp)
        Text(localized("ui.parameters_which_can_affect_how_this_step"), color = StarColors.textSecondary, fontSize = 11.sp, modifier = Modifier.padding(bottom = 6.dp))
        val listed = args
        if (listed == null) {
            Text(localized("ui.loading_args"), color = StarColors.textSecondary, fontSize = 11.sp)
        } else {
            for (arg in listed) {
                ArgRow(arg) { value ->
                    scope.launch {
                        val updated = vm.setHoughArg(arg.name, value)
                        if (updated.isNotEmpty()) { args = updated; onChanged() }
                    }
                }
            }
        }
    }
}

@OptIn(ExperimentalComposeUiApi::class)
@Composable
private fun ArgRow(arg: HoughLineFinderArg, onCommit: (Double) -> Unit) {
    fun show(v: Double) = if (arg.isInteger) v.toLong().toString() else HoughLines.format(v)
    var text by remember(arg.name, arg.value) { mutableStateOf(show(arg.value)) }
    fun commit() {
        val v = text.trim().toDoubleOrNull()
        if (v == null) { text = show(arg.value); return }   // not a number: back to what it is
        if (v != arg.value) onCommit(v)
    }
    Column(Modifier.padding(vertical = 4.dp)) {
        Row(verticalAlignment = androidx.compose.ui.Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(arg.name, color = StarColors.textPrimary, fontSize = 11.sp, modifier = Modifier.weight(1f))
            BasicTextField(
                value = text,
                onValueChange = { text = it },
                singleLine = true,
                textStyle = TextStyle(color = StarColors.white, fontSize = 11.sp),
                cursorBrush = SolidColor(StarColors.white),
                modifier = Modifier
                    .width(80.dp)
                    .clip(RoundedCornerShape(3.dp))
                    .background(StarColors.cellDefault)
                    .padding(horizontal = 4.dp, vertical = 2.dp)
                    .onPreviewKeyEvent { e ->
                        if (e.type == KeyEventType.KeyDown && (e.key == Key.Enter || e.key == Key.NumPadEnter)) { commit(); true } else false
                    }
                    .onFocusChanged { if (!it.isFocused) commit() },
            )
        }
        Text(arg.description.replace(Regex("\\s+"), " ").trim(), color = StarColors.textDisabled, fontSize = 10.sp)
    }
}
