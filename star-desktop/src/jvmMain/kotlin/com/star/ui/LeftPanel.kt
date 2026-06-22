package com.star.ui

import androidx.compose.foundation.*
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.*
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.*
import com.star.data.ProcessingStatus
import com.star.ui.theme.StarColors
import com.star.viewmodel.SequenceViewModel

/**
 * Left panel: processing controls, progress, and operation queue stats.
 * Mirrors LeftPanel.swift + BottomLeftView.swift + ProgressBars.swift.
 */
@Composable
fun LeftPanel(
    sequenceViewModel: SequenceViewModel,
    modifier: Modifier = Modifier,
    onCollapse: () -> Unit,
    onShowProcessingSettings: () -> Unit,
) {
    val processingStatus by sequenceViewModel.processingStatus.collectAsState()
    val isProcessing = processingStatus is ProcessingStatus.Running

    Column(
        modifier
            .background(StarColors.panelBackground)
            .border(BorderStroke(0.5.dp, StarColors.panelBorder))
            .verticalScroll(rememberScrollState())
            .padding(8.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        // Panel header + collapse
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
            Text("Controls", style = MaterialTheme.typography.labelLarge, color = StarColors.textPrimary)
            IconButton(onClick = onCollapse, modifier = Modifier.size(24.dp)) {
                Text("‹", color = StarColors.textSecondary)
            }
        }

        Divider(color = StarColors.panelBorder, thickness = 0.5.dp)

        // Processing buttons (mirrors ProcessAllFramesButton.swift etc.)
        PanelButton(
            label = "Process All Frames",
            enabled = !isProcessing,
            onClick = { sequenceViewModel.processAll() },
        )
        PanelButton(
            label = "Process Remaining",
            enabled = !isProcessing,
            onClick = { sequenceViewModel.processRemaining() },
        )
        PanelButton(
            label = "Process Current Frame",
            enabled = !isProcessing,
            onClick = { sequenceViewModel.processCurrentFrame() },
        )
        PanelButton(
            label = "Reprocess Current Frame",
            enabled = !isProcessing,
            onClick = { sequenceViewModel.processCurrentFrame(force = true) },
        )

        if (isProcessing) {
            PanelButton(
                label = "Cancel Processing",
                enabled = true,
                onClick = { sequenceViewModel.cancelProcessing() },
                containerColor = MaterialTheme.colorScheme.error,
            )
        }

        Divider(color = StarColors.panelBorder, thickness = 0.5.dp)

        // Render buttons (mirrors RenderAllFramesButton.swift etc.)
        PanelButton(
            label = "Render All Frames",
            enabled = !isProcessing,
            onClick = {
                sequenceViewModel.renderSequence({}, {}, {})
            },
        )

        Divider(color = StarColors.panelBorder, thickness = 0.5.dp)

        // Processing settings
        OutlinedButton(
            onClick = onShowProcessingSettings,
            modifier = Modifier.fillMaxWidth(),
        ) {
            Text("Processing Settings…", fontSize = 12.sp)
        }

        Divider(color = StarColors.panelBorder, thickness = 0.5.dp)

        // Progress section
        ProgressSection(
            sequenceViewModel = sequenceViewModel,
            modifier = Modifier.fillMaxWidth(),
        )
    }
}

@Composable
internal fun PanelButton(
    label: String,
    enabled: Boolean,
    onClick: () -> Unit,
    containerColor: Color = StarColors.buttonBg,
) {
    Button(
        onClick = onClick,
        enabled = enabled,
        modifier = Modifier.fillMaxWidth().height(32.dp),
        contentPadding = PaddingValues(horizontal = 8.dp, vertical = 0.dp),
        colors = ButtonDefaults.buttonColors(
            containerColor = containerColor,
            disabledContainerColor = containerColor.copy(alpha = 0.4f),
        ),
    ) {
        Text(label, fontSize = 11.sp, maxLines = 1)
    }
}
