package com.star.ui

import androidx.compose.foundation.*
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.*
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.*
import com.star.ui.theme.StarColors
import com.star.viewmodel.*

/**
 * Secondary outlier window — mirrors OutlierWindowView.swift + OutlierGroupTable.swift.
 * Shows a table of outlier groups for the current frame with sort and filter controls.
 */
@Composable
fun OutlierWindowView(
    frameViewModel: FrameViewModel?,
    outlierWindowVm: OutlierWindowViewModel,
) {
    val outlierGroups by (frameViewModel?.outlierGroups?.collectAsState() ?: remember { mutableStateOf(emptyList()) })
    val showOnlyUndecided by outlierWindowVm.showOnlyUndecided.collectAsState()
    val selectedGroupId by outlierWindowVm.selectedGroupId.collectAsState()

    val displayGroups = remember(outlierGroups, showOnlyUndecided) {
        if (showOnlyUndecided) outlierGroups.filter { it.decision.willRemove == null } else outlierGroups
    }

    Column(Modifier.fillMaxSize().background(StarColors.panelBackground)) {
        // Header
        Row(
            Modifier.fillMaxWidth().padding(8.dp),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text("Outlier Groups (${displayGroups.size})", style = MaterialTheme.typography.titleSmall, color = StarColors.textPrimary)
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("Undecided only", fontSize = 11.sp, color = StarColors.textSecondary)
                Switch(
                    checked = showOnlyUndecided,
                    onCheckedChange = { outlierWindowVm.toggleShowOnlyUndecided() },
                    modifier = Modifier.padding(start = 4.dp),
                )
            }
        }

        Divider(color = StarColors.panelBorder)

        // Column headers
        OutlierTableHeader()
        Divider(color = StarColors.panelBorder)

        LazyColumn(Modifier.fillMaxSize()) {
            items(displayGroups) { group ->
                OutlierTableRow(
                    group = group,
                    isSelected = group.id == selectedGroupId,
                    onClick = { outlierWindowVm.selectGroup(group.id) },
                )
                Divider(color = StarColors.panelBorder, thickness = 0.5.dp)
            }
        }
    }
}

@Composable
private fun OutlierTableHeader() {
    Row(Modifier.fillMaxWidth().padding(horizontal = 8.dp, vertical = 4.dp)) {
        TableCell("ID", weight = 0.1f, header = true)
        TableCell("Size", weight = 0.15f, header = true)
        TableCell("Score", weight = 0.15f, header = true)
        TableCell("Decision", weight = 0.3f, header = true)
        TableCell("Bounds", weight = 0.3f, header = true)
    }
}

@Composable
private fun OutlierTableRow(
    group: OutlierGroupState,
    isSelected: Boolean,
    onClick: () -> Unit,
) {
    val decisionText = when (group.decision.willRemove) {
        true  -> "Remove"
        false -> "Keep"
        null  -> "Undecided"
    }
    val decisionColor = when (group.decision.willRemove) {
        true  -> Color.Red
        false -> Color.Green
        null  -> Color.Blue
    }

    Row(
        Modifier
            .fillMaxWidth()
            .background(if (isSelected) Color(0xFF37474F) else Color.Transparent)
            .clickable(onClick = onClick)
            .padding(horizontal = 8.dp, vertical = 4.dp),
    ) {
        TableCell("${group.id}", weight = 0.1f)
        TableCell("${group.size}", weight = 0.15f)
        TableCell("%.2f".format(group.classificationScore), weight = 0.15f)
        TableCell(decisionText, weight = 0.3f, color = decisionColor)
        TableCell(
            "${group.bounds.minX},${group.bounds.minY}–${group.bounds.maxX},${group.bounds.maxY}",
            weight = 0.3f,
        )
    }
}

@Composable
private fun RowScope.TableCell(
    text: String,
    weight: Float,
    header: Boolean = false,
    color: Color = StarColors.textPrimary,
) {
    Text(
        text,
        modifier = Modifier.weight(weight),
        fontSize = if (header) 10.sp else 11.sp,
        color = if (header) StarColors.textSecondary else color,
        fontWeight = if (header) androidx.compose.ui.text.font.FontWeight.Bold else null,
    )
}
