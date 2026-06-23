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
import com.star.desktop.domain.FastAdvancementType
import com.star.desktop.domain.ToolType
import com.star.desktop.ui.components.toolPainter
import com.star.desktop.ui.theme.StarColors
import com.star.proto.CleanMethod

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
    val info by fvm.info.collectAsState()
    val fastAdv by vm.fastAdvancement.collectAsState()

    Column(modifier.width(150.dp).fillMaxHeight().background(StarColors.sidePanel)) {
      Column(
        modifier = Modifier
            .weight(1f)
            .fillMaxWidth()
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
        BulkButton("Apply Decision Tree", StarColors.blue) { fvm.applyDecisionTree(overwrite = true) }
        BulkButton("Apply Tree (All Frames)", StarColors.blue) { vm.applyDecisionTreeAll() }
        selected?.let { Text("Selected #$it", color = StarColors.orange, fontSize = 10.sp) }

        androidx.compose.material3.HorizontalDivider(color = StarColors.cellDefault, modifier = Modifier.padding(vertical = 4.dp))
        Text("Clean Method", color = StarColors.textPrimary, fontWeight = FontWeight.SemiBold, fontSize = 12.sp)
        val activeMethod = info?.cleanMethod ?: CleanMethod.CLEAN_SELECTIVE
        val cmLabels = CLEAN_METHODS.toMap()
        com.star.desktop.ui.components.VerticalStarPicker(
            options = CLEAN_METHODS.map { it.first },
            selected = activeMethod,
            label = { cmLabels[it] ?: "" },
            onSelect = { fvm.setCleanMethod(it) },
            modifier = Modifier.fillMaxWidth(),
        )

        androidx.compose.material3.HorizontalDivider(color = StarColors.cellDefault, modifier = Modifier.padding(vertical = 4.dp))
        Text("Fast Skip (z / x)", color = StarColors.textPrimary, fontWeight = FontWeight.SemiBold, fontSize = 12.sp)
        val fastLabels = FAST_MODES.toMap()
        com.star.desktop.ui.components.VerticalStarPicker(
            options = FAST_MODES.map { it.first },
            selected = fastAdv,
            label = { fastLabels[it] ?: "" },
            onSelect = { vm.setFastAdvancement(it) },
            modifier = Modifier.fillMaxWidth(),
        )
      }
      com.star.desktop.ui.components.PanelChevron("»", { vm.setRightPanel(false) }, Modifier.padding(6.dp))
    }
}

/** Per-frame clean methods (proto `CleanMethod`) with display labels matching the macOS picker. */
private val CLEAN_METHODS: List<Pair<CleanMethod, String>> = listOf(
    CleanMethod.CLEAN_AUTOMATIC to "Automatic",
    CleanMethod.CLEAN_AUTOMATIC_TRUE to "Auto + Outliers",
    CleanMethod.CLEAN_SELECTIVE to "Selective",
)

/** Fast-skip strategies for the z/x transport keys (macOS `FastAdvancementType`). */
private val FAST_MODES: List<Pair<FastAdvancementType, String>> = listOf(
    FastAdvancementType.NORMAL to "Skip 20 frames",
    FastAdvancementType.SKIP_EMPTIES to "Skip empty frames",
    FastAdvancementType.TO_NEXT_POSITIVE to "Next w/ removals",
    FastAdvancementType.TO_NEXT_NEGATIVE to "Next w/ keeps",
    FastAdvancementType.TO_NEXT_UNKNOWN to "Next undecided",
)

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
