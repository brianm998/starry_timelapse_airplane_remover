package com.star.desktop.ui.sequence

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.star.desktop.domain.ToolType
import com.star.desktop.ui.components.toolPainter
import com.star.desktop.ui.theme.StarColors

/**
 * Right panel (macOS `RightPanel`): the editing tool picker. Tool *paint* behavior is wired in
 * Phase 4 (outlier editing); this presents the 8 tools (shortcuts 1–8) with selection highlight.
 */
@Composable
fun RightPanel(vm: SequenceViewModel, modifier: Modifier = Modifier) {
    val tool by vm.tool.collectAsState()
    val current by vm.currentIndex.collectAsState()
    val fvm = androidx.compose.runtime.remember(current) { vm.frameVMFor(current) }
    val groups by fvm.groups.collectAsState()
    val decisions by fvm.decisions.collectAsState()
    val selected by fvm.selected.collectAsState()

    Column(
        modifier = modifier
            .width(150.dp)
            .fillMaxHeight()
            .background(StarColors.sidePanel)
            .verticalScroll(rememberScrollState())
            .padding(8.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Text("Tools", color = StarColors.textPrimary, fontWeight = FontWeight.SemiBold, fontSize = 13.sp)
        ToolType.selectable.forEachIndexed { i, t ->
            ToolRow(t, number = i + 1, selected = t == tool, onClick = { vm.setTool(t) })
        }

        androidx.compose.material3.HorizontalDivider(color = StarColors.cellDefault, modifier = Modifier.padding(vertical = 4.dp))

        val remove = groups.count { com.star.desktop.domain.OutlierDecisions.willRemove(decisions[it.id] ?: it.shouldRemove) == true }
        val keep = groups.count { com.star.desktop.domain.OutlierDecisions.willRemove(decisions[it.id] ?: it.shouldRemove) == false }
        val undecided = groups.size - remove - keep
        Text("Outliers (${groups.size})", color = StarColors.textPrimary, fontWeight = FontWeight.SemiBold, fontSize = 12.sp)
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Text("✕$remove", color = StarColors.red, fontSize = 11.sp)
            Text("✓$keep", color = StarColors.green, fontSize = 11.sp)
            Text("?$undecided", color = StarColors.orange, fontSize = 11.sp)
        }
        BulkButton("Keep All", StarColors.green) { fvm.keepAll() }
        BulkButton("Remove All", StarColors.red) { fvm.removeAll() }
        BulkButton("Clear Undecided", StarColors.gray) { fvm.clearUndecided() }
        selected?.let { Text("Selected #$it", color = StarColors.orange, fontSize = 10.sp) }
    }
}

@Composable
private fun BulkButton(label: String, color: Color, onClick: () -> Unit) {
    androidx.compose.material3.OutlinedButton(
        onClick = onClick,
        colors = androidx.compose.material3.ButtonDefaults.outlinedButtonColors(contentColor = color),
        contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = 8.dp, vertical = 4.dp),
        modifier = Modifier.fillMaxWidth(),
    ) { Text(label, fontSize = 11.sp) }
}

@Composable
private fun ToolRow(tool: ToolType, number: Int, selected: Boolean, onClick: () -> Unit) {
    val accent = StarColors.toolColor(tool)
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(5.dp))
            .background(if (selected) accent.copy(alpha = 0.22f) else Color.Transparent)
            .then(if (selected) Modifier.border(1.dp, SolidColor(accent), RoundedCornerShape(5.dp)) else Modifier)
            .clickable(onClick = onClick)
            .padding(4.dp),
    ) {
        Icon(
            painter = toolPainter(tool),
            contentDescription = tool.displayName,
            tint = Color.Unspecified,
            modifier = Modifier.size(28.dp),
        )
        Column {
            Text(tool.displayName, color = StarColors.textPrimary, fontSize = 11.sp)
            Text("$number", color = StarColors.textDisabled, fontSize = 9.sp)
        }
    }
}
