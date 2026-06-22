package com.star.ui

import androidx.compose.foundation.*
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.*
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.*
import com.star.proto.CleanMethod
import com.star.proto.FrameViewMode
import com.star.ui.theme.StarColors
import com.star.viewmodel.FrameViewModel
import com.star.viewmodel.ToolType

/**
 * Right panel: tool picker + view mode + per-frame settings + bulk outlier ops.
 * Mirrors RightPanel.swift + BottomRightView.swift + ChangeToolButton.swift.
 */
@Composable
fun RightPanel(
    frameViewModel: FrameViewModel?,
    activeTool: ToolType,
    onToolChange: (ToolType) -> Unit,
    modifier: Modifier = Modifier,
    onCollapse: () -> Unit,
    onShowRenderVideo: () -> Unit,
) {
    val frameInfo by (frameViewModel?.frameInfo?.collectAsState() ?: remember { mutableStateOf(null) })
    val viewMode by (frameViewModel?.viewMode?.collectAsState() ?: remember { mutableStateOf(FrameViewMode.VIEW_ORIGINAL) })

    Column(
        modifier
            .background(StarColors.panelBackground)
            .border(BorderStroke(0.5.dp, StarColors.panelBorder))
            .verticalScroll(rememberScrollState())
            .padding(8.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
            Text("Tools", style = MaterialTheme.typography.labelLarge, color = StarColors.textPrimary)
            IconButton(onClick = onCollapse, modifier = Modifier.size(24.dp)) {
                Text("›", color = StarColors.textSecondary)
            }
        }

        Divider(color = StarColors.panelBorder, thickness = 0.5.dp)

        // Tool picker: 8 tools mapped to keys 1–8
        ToolGrid(activeTool = activeTool, onToolChange = onToolChange)

        Divider(color = StarColors.panelBorder, thickness = 0.5.dp)

        // View mode
        Text("View Mode", style = MaterialTheme.typography.labelSmall, color = StarColors.textSecondary)
        listOf(FrameViewMode.VIEW_ORIGINAL, FrameViewMode.VIEW_PROCESSED, FrameViewMode.VIEW_SUBTRACTION, FrameViewMode.VIEW_VALIDATION).forEach { mode ->
            val label = when (mode) {
                FrameViewMode.VIEW_ORIGINAL    -> "Original"
                FrameViewMode.VIEW_PROCESSED   -> "Processed"
                FrameViewMode.VIEW_SUBTRACTION -> "Subtraction"
                FrameViewMode.VIEW_VALIDATION  -> "Validation"
                else -> mode.name
            }
            Row(
                Modifier
                    .fillMaxWidth()
                    .clickable { frameViewModel?.setViewMode(mode) }
                    .padding(4.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                RadioButton(
                    selected = viewMode == mode,
                    onClick = { frameViewModel?.setViewMode(mode) },
                    modifier = Modifier.size(16.dp),
                )
                Spacer(Modifier.width(4.dp))
                Text(label, fontSize = 11.sp, color = StarColors.textPrimary)
            }
        }

        Divider(color = StarColors.panelBorder, thickness = 0.5.dp)

        // Bulk outlier operations
        Text("Outlier Decisions", style = MaterialTheme.typography.labelSmall, color = StarColors.textSecondary)
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(4.dp)) {
            SmallButton("Keep All",   Color(0xFF4CAF50)) { frameViewModel?.keepAll() }
            SmallButton("Remove All", Color(0xFFF44336)) { frameViewModel?.removeAll() }
        }
        SmallButton("Clear Undecided", Color(0xFF2196F3), Modifier.fillMaxWidth()) { frameViewModel?.clearUndecided() }

        Divider(color = StarColors.panelBorder, thickness = 0.5.dp)

        // Per-frame clean method override
        frameInfo?.let { info ->
            Text("Clean Method", style = MaterialTheme.typography.labelSmall, color = StarColors.textSecondary)
            listOf(CleanMethod.CLEAN_AUTOMATIC, CleanMethod.CLEAN_AUTOMATIC_TRUE, CleanMethod.CLEAN_SELECTIVE).forEach { method ->
                val label = when (method) {
                    CleanMethod.CLEAN_AUTOMATIC      -> "Automatic"
                    CleanMethod.CLEAN_AUTOMATIC_TRUE -> "Automatic (Force)"
                    CleanMethod.CLEAN_SELECTIVE      -> "Selective"
                    else -> method.name
                }
                Row(
                    Modifier.fillMaxWidth().clickable { frameViewModel?.setCleanMethod(method) }.padding(4.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    RadioButton(
                        selected = info.cleanMethod == method,
                        onClick = { frameViewModel?.setCleanMethod(method) },
                        modifier = Modifier.size(16.dp),
                    )
                    Spacer(Modifier.width(4.dp))
                    Text(label, fontSize = 11.sp, color = StarColors.textPrimary)
                }
            }
        }

        Divider(color = StarColors.panelBorder, thickness = 0.5.dp)

        // Render controls
        Text("Render", style = MaterialTheme.typography.labelSmall, color = StarColors.textSecondary)
        PanelButton("Render Current Frame", enabled = true, onClick = { frameViewModel?.requestRerender() })
        OutlinedButton(
            onClick = onShowRenderVideo,
            modifier = Modifier.fillMaxWidth().height(32.dp),
            contentPadding = PaddingValues(horizontal = 8.dp, vertical = 0.dp),
        ) {
            Text("Export Video…", fontSize = 11.sp)
        }
    }
}

@Composable
private fun RowScope.SmallButton(label: String, color: Color, onClick: () -> Unit) {
    Button(
        onClick = onClick,
        modifier = Modifier.weight(1f).height(28.dp),
        contentPadding = PaddingValues(horizontal = 4.dp, vertical = 0.dp),
        colors = ButtonDefaults.buttonColors(containerColor = color.copy(alpha = 0.7f)),
    ) {
        Text(label, fontSize = 10.sp, maxLines = 1)
    }
}

@Composable
private fun SmallButton(label: String, color: Color, modifier: Modifier = Modifier, onClick: () -> Unit) {
    Button(
        onClick = onClick,
        modifier = modifier.height(28.dp),
        contentPadding = PaddingValues(horizontal = 4.dp, vertical = 0.dp),
        colors = ButtonDefaults.buttonColors(containerColor = color.copy(alpha = 0.7f)),
    ) {
        Text(label, fontSize = 10.sp)
    }
}

@Composable
private fun ToolGrid(activeTool: ToolType, onToolChange: (ToolType) -> Unit) {
    val tools = ToolType.values().filter { it != ToolType.None }
    // 2×4 grid
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        tools.chunked(2).forEachIndexed { rowIdx, rowTools ->
            Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                rowTools.forEachIndexed { colIdx, tool ->
                    val keyNum = rowIdx * 2 + colIdx + 1
                    ToolButton(
                        tool = tool,
                        keyNum = keyNum,
                        isActive = tool == activeTool,
                        onClick = { onToolChange(tool) },
                        modifier = Modifier.weight(1f),
                    )
                }
            }
        }
    }
}

@Composable
private fun ToolButton(
    tool: ToolType,
    keyNum: Int,
    isActive: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val label = when (tool) {
        ToolType.Remove          -> "Remove"
        ToolType.Keep            -> "Keep"
        ToolType.Razor           -> "Razor"
        ToolType.Shovel          -> "Shovel"
        ToolType.Trash           -> "Trash"
        ToolType.RemoveFromTrash -> "Untrash"
        ToolType.Multi           -> "Multi"
        ToolType.Information     -> "Info"
        ToolType.None            -> "None"
    }
    Button(
        onClick = onClick,
        modifier = modifier.height(36.dp),
        contentPadding = PaddingValues(horizontal = 4.dp, vertical = 0.dp),
        colors = ButtonDefaults.buttonColors(
            containerColor = if (isActive) Color(0xFF455A64) else StarColors.buttonBg,
        ),
    ) {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Text(label, fontSize = 9.sp, maxLines = 1, color = StarColors.textPrimary)
            Text("[$keyNum]", fontSize = 8.sp, color = StarColors.textSecondary)
        }
    }
}
