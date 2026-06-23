package com.star.desktop.ui.windows

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.star.desktop.domain.OutlierDecisions
import com.star.desktop.ui.sequence.SequenceViewModel
import com.star.desktop.ui.theme.StarColors
import com.star.proto.RemoveReason

/**
 * The Outlier table (macOS `OutlierGroupTable` / `OutlierWindowView`), shown as a secondary window.
 * Lists the current frame's groups; rows select (highlighting the overlay) and toggle keep/remove.
 */
@Composable
fun OutlierWindowView(vm: SequenceViewModel) {
    val current by vm.currentIndex.collectAsState()
    val fvm = remember(current) { vm.frameVMFor(current) }
    val groups by fvm.groups.collectAsState()
    val decisions by fvm.decisions.collectAsState()
    val selected by fvm.selected.collectAsState()

    Column(Modifier.fillMaxSize().background(StarColors.appBackground)) {
        Row(
            Modifier.fillMaxWidth().background(StarColors.sidePanel).padding(horizontal = 10.dp, vertical = 6.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            HeaderCell("Frame ${current + 1}", 1.2f)
            HeaderCell("size", 0.8f)
            HeaderCell("bounds", 2f)
            HeaderCell("score", 0.8f)
            HeaderCell("decision", 1f)
        }
        if (groups.isEmpty()) {
            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                Text("No outlier groups (process in Selective mode)", color = StarColors.textDisabled, fontSize = 12.sp)
            }
        } else {
            LazyColumn(Modifier.fillMaxSize()) {
                items(groups, key = { it.id }) { g ->
                    val reason = decisions[g.id] ?: g.shouldRemove
                    val isSel = selected == g.id
                    Row(
                        Modifier
                            .fillMaxWidth()
                            .background(if (isSel) StarColors.cellSelected else StarColors.appBackground)
                            .clickable { fvm.selectGroup(g.id) }
                            .padding(horizontal = 10.dp, vertical = 4.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        Cell("#${g.id}", 1.2f)
                        Cell("${g.size}", 0.8f)
                        Cell("(${g.bounds.minX},${g.bounds.minY})-(${g.bounds.maxX},${g.bounds.maxY})", 2f)
                        Cell(String.format("%.2f", g.classificationScore), 0.8f)
                        Box(Modifier.weight(1f)) {
                            val (txt, color) = when (OutlierDecisions.willRemove(reason)) {
                                true -> "remove" to StarColors.red
                                false -> "keep" to StarColors.green
                                null -> "undecided" to StarColors.orange
                            }
                            Text(txt, color = color, fontSize = 11.sp, modifier = Modifier.clickable { fvm.toggle(g.id) })
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun androidx.compose.foundation.layout.RowScope.HeaderCell(text: String, weight: Float) {
    Text(text, color = StarColors.textSecondary, fontSize = 11.sp, fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(weight))
}

@Composable
private fun androidx.compose.foundation.layout.RowScope.Cell(text: String, weight: Float) {
    Text(text, color = StarColors.textPrimary, fontSize = 11.sp, modifier = Modifier.weight(weight))
}
