package com.star.desktop.ui.windows

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Checkbox
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.input.pointer.PointerEventType
import androidx.compose.ui.input.pointer.isCtrlPressed
import androidx.compose.ui.input.pointer.isMetaPressed
import androidx.compose.ui.input.pointer.isPrimaryPressed
import androidx.compose.ui.input.pointer.isShiftPressed
import androidx.compose.ui.input.pointer.onPointerEvent
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.star.desktop.domain.OutlierDecisions
import com.star.desktop.domain.OutlierTable
import com.star.desktop.i18n.localized
import com.star.desktop.ui.sequence.SequenceViewModel
import com.star.desktop.ui.sequence.edit.OutlierOverlay
import com.star.desktop.ui.theme.StarColors
import com.star.proto.OutlierFeatureRow
import com.star.proto.RemoveReason

private val DECISION_WIDTH = 80.dp
private val SIZE_WIDTH = 80.dp
private val COLUMN_WIDTH = 120.dp

/**
 * The outlier window (macOS `OutlierWindowView` / `OutlierGroupTable`): a table of outlier groups with the decision-tree values behind
 * the classifier's choices. It lists the groups an Information click or box named (or, opened from the menu, those of the frame being
 * looked at); the headers sort it, rows select (one, several with Ctrl/Cmd or Shift) and the selected groups are drawn selected on the
 * frame, and a chooser picks which of the optional columns show.
 */
@OptIn(ExperimentalComposeUiApi::class)
@Composable
fun OutlierWindowView(vm: SequenceViewModel) {
    val current by vm.currentIndex.collectAsState()
    val info by vm.infoRows.collectAsState()
    val windowFrame = info?.frameIndex ?: current
    val fvm = remember(windowFrame) { vm.frameVMFor(windowFrame) }
    LaunchedEffect(windowFrame) { fvm.load() }
    // Without this the highlight would outlast the window (macOS clears it when the table disappears).
    DisposableEffect(Unit) { onDispose { vm.outlierWindowClosed() } }

    val groups by fvm.groups.collectAsState()
    val decisions by fvm.decisions.collectAsState()
    val selection by fvm.selection.collectAsState()
    val chosenColumns by vm.outlierColumns.collectAsState()

    // The groups listed: the ones named, or all the frame has that are a thing of their own on screen (the small ones are drawn in
    // masks, and tabulating thousands of specks tells nobody anything).
    val wantedIds = remember(info, groups) { info?.groupIds ?: groups.filter(OutlierOverlay::isLarge).map { it.id } }
    var features by remember(windowFrame) { mutableStateOf<Map<Int, OutlierFeatureRow>?>(null) }
    LaunchedEffect(windowFrame, wantedIds) {
        features = null
        features = vm.outlierFeatures(windowFrame, wantedIds)
    }

    val rows = remember(features, groups, wantedIds) {
        val loaded = features ?: return@remember null
        val bySize = groups.associateBy { it.id }
        wantedIds.mapNotNull { id ->
            val g = bySize[id] ?: return@mapNotNull null
            val f = loaded[id]
            OutlierTable.Row(id, g.size, f?.featuresMap ?: emptyMap(), f?.classification ?: 0.0)
        }
    }

    var sort by remember { mutableStateOf(OutlierTable.defaultSort) }
    val sorted = remember(rows, sort, decisions) {
        rows?.let { OutlierTable.sorted(it, sort) { id -> decisions[id] ?: RemoveReason.RR_UNDECIDED } }
    }
    var anchor by remember(windowFrame) { mutableStateOf<Int?>(null) }
    var chooserOpen by remember { mutableStateOf(false) }
    val visible = remember(chosenColumns) { OutlierTable.visible(chosenColumns) }

    Column(Modifier.fillMaxSize().background(StarColors.appBackground).padding(8.dp)) {
    Row(Modifier.weight(1f).fillMaxWidth()) {
        Column(Modifier.weight(1f).fillMaxHeight()) {
            Text(
                localized("ui.info_about_n_outlier_groups", sorted?.size ?: 0),
                color = StarColors.textPrimary, fontWeight = FontWeight.SemiBold, fontSize = 13.sp,
                modifier = Modifier.padding(bottom = 6.dp),
            )
            when {
                sorted == null -> Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    Text(localized("ui.loading_outliers_for_this_frame"), color = StarColors.textSecondary, fontSize = 12.sp)
                    LinearProgressIndicator(Modifier.weight(1f), color = StarColors.white, trackColor = StarColors.cellDefault)
                }
                sorted.isEmpty() -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    Text(localized("ui.no_outlier_groups_process_in_selective_mode"), color = StarColors.textDisabled, fontSize = 12.sp)
                }
                else -> {
                    val tableWidth = DECISION_WIDTH + SIZE_WIDTH + COLUMN_WIDTH * visible.size
                    Box(Modifier.fillMaxSize().horizontalScroll(rememberScrollState())) {
                        Column(Modifier.width(tableWidth).fillMaxHeight()) {
                            Row(Modifier.fillMaxWidth().background(StarColors.sidePanel).padding(vertical = 6.dp)) {
                                Header(localized("ui.remove"), OutlierTable.DECISION, sort, DECISION_WIDTH) { sort = OutlierTable.clicked(sort, it) }
                                Header(localized("ui.size"), OutlierTable.SIZE, sort, SIZE_WIDTH) { sort = OutlierTable.clicked(sort, it) }
                                for (c in visible) Header(localized(c.labelKey), c.key, sort, COLUMN_WIDTH) { sort = OutlierTable.clicked(sort, it) }
                            }
                            val order = sorted.map { it.groupId }
                            LazyColumn(Modifier.fillMaxWidth().weight(1f)) {
                                items(sorted, key = { it.groupId }) { row ->
                                    val reason = decisions[row.groupId] ?: RemoveReason.RR_UNDECIDED
                                    Row(
                                        Modifier
                                            .fillMaxWidth()
                                            .background(if (row.groupId in selection) StarColors.cellSelected else StarColors.appBackground)
                                            .onPointerEvent(PointerEventType.Press) { ev ->
                                                if (!ev.buttons.isPrimaryPressed) return@onPointerEvent
                                                val m = ev.keyboardModifiers
                                                val next = OutlierTable.click(
                                                    OutlierTable.Selection(selection, anchor), order, row.groupId,
                                                    toggle = m.isCtrlPressed || m.isMetaPressed, extend = m.isShiftPressed,
                                                )
                                                anchor = next.anchor
                                                fvm.selectGroups(next.ids)
                                            }
                                            .padding(vertical = 4.dp),
                                        verticalAlignment = Alignment.CenterVertically,
                                    ) {
                                        DecisionCell(reason, DECISION_WIDTH) { fvm.toggle(row.groupId) }
                                        Cell("${row.size}", SIZE_WIDTH)
                                        for (c in visible) {
                                            val v = OutlierTable.value(row, c)
                                            Cell(if (c.source == OutlierTable.Source.ID) "${row.groupId}" else OutlierTable.formatG(v), COLUMN_WIDTH)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        if (chooserOpen) {
            ColumnChooser(vm, chosenColumns, onClose = { chooserOpen = false })
        } else {
            Text("«", color = StarColors.textSecondary, fontSize = 16.sp, modifier = Modifier.clickable { chooserOpen = true }.padding(horizontal = 6.dp))
        }
    }
    OutlierLinesPanel(vm, windowFrame, selection, groups)
    }
}

@Composable
private fun Header(text: String, key: String, sort: OutlierTable.Sort, width: Dp, onClick: (String) -> Unit) {
    val arrow = if (sort.key == key) (if (sort.ascending) " ▲" else " ▼") else ""
    Text(
        text + arrow,
        color = StarColors.textSecondary, fontSize = 11.sp, fontWeight = FontWeight.SemiBold, maxLines = 1,
        modifier = Modifier.width(width).clickable { onClick(key) }.padding(horizontal = 6.dp),
    )
}

@Composable
private fun Cell(text: String, width: Dp) {
    Text(text, color = StarColors.textPrimary, fontSize = 11.sp, maxLines = 1, modifier = Modifier.width(width).padding(horizontal = 6.dp))
}

/** The group's decision as the glyphs the right panel counts them with; clicking it toggles keep and remove. */
@Composable
private fun DecisionCell(reason: RemoveReason, width: Dp, onToggle: () -> Unit) {
    val (glyph, color) = when (OutlierDecisions.willRemove(reason)) {
        true -> "✕" to StarColors.red
        false -> "✓" to StarColors.green
        null -> "?" to StarColors.orange
    }
    Text(glyph, color = color, fontSize = 13.sp, modifier = Modifier.width(width).clickable(onClick = onToggle).padding(horizontal = 6.dp))
}

/** The panel that picks which optional columns show (macOS "Select which columns to show"). */
@Composable
private fun ColumnChooser(vm: SequenceViewModel, chosen: Set<String>, onClose: () -> Unit) {
    Column(Modifier.width(240.dp).fillMaxHeight().padding(start = 8.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            Text("»", color = StarColors.textSecondary, fontSize = 16.sp, modifier = Modifier.clickable(onClick = onClose).padding(horizontal = 4.dp))
            Text(localized("ui.select_which_columns_to_show"), color = StarColors.textPrimary, fontSize = 12.sp)
        }
        Row(Modifier.padding(vertical = 6.dp), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            OutlinedButton(onClick = { vm.setAllOutlierColumns(true) }) { Text(localized("ui.select_all"), fontSize = 11.sp) }
            OutlinedButton(onClick = { vm.setAllOutlierColumns(false) }) { Text(localized("ui.clear_all"), fontSize = 11.sp) }
        }
        Column(Modifier.weight(1f).verticalScroll(rememberScrollState())) {
            for (c in OutlierTable.columns) {
                Row(Modifier.fillMaxWidth().clickable { vm.setOutlierColumn(c.key, c.key !in chosen) }, verticalAlignment = Alignment.CenterVertically) {
                    Checkbox(checked = c.key in chosen, onCheckedChange = { vm.setOutlierColumn(c.key, it) })
                    Text(localized(c.labelKey), color = StarColors.textPrimary, fontSize = 11.sp)
                }
            }
        }
    }
}
