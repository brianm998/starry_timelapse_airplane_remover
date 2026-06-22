package com.star.ui

import androidx.compose.foundation.layout.*
import androidx.compose.runtime.*
import androidx.compose.ui.*
import androidx.compose.ui.input.key.*
import androidx.compose.ui.unit.*
import com.star.viewmodel.*

/**
 * Three-mode container: Edit / Scrub / Grid.
 * Mirrors ContentView.swift — switches on [interactionMode].
 * Keyboard shortcuts E/S/G switch modes; arrow keys navigate frames; 1–8 select tools.
 */
@Composable
fun MainView(
    appViewModel: AppViewModel,
    sequenceViewModel: SequenceViewModel,
    interactionMode: InteractionMode,
) {
    val currentFrameIndex by sequenceViewModel.currentFrameIndex.collectAsState()
    val frameViewModel by sequenceViewModel.frameViewModel.collectAsState()
    var activeTool by remember { mutableStateOf(ToolType.Remove) }
    var showRenderVideoDialog by remember { mutableStateOf(false) }
    var showProcessingSettings by remember { mutableStateOf(false) }

    Box(
        Modifier
            .fillMaxSize()
            .onPreviewKeyEvent { event ->
                if (event.type != KeyEventType.KeyDown) return@onPreviewKeyEvent false
                when (event.key) {
                    // Mode switching
                    Key.E -> { appViewModel.setMode(InteractionMode.Edit);  true }
                    Key.S -> { appViewModel.setMode(InteractionMode.Scrub); true }
                    Key.G -> { appViewModel.setMode(InteractionMode.Grid);  true }
                    // Frame navigation
                    Key.DirectionRight -> { sequenceViewModel.nextFrame(); true }
                    Key.DirectionLeft  -> { sequenceViewModel.prevFrame(); true }
                    // Tool selection 1–8
                    Key.One   -> { activeTool = ToolType.Remove;          true }
                    Key.Two   -> { activeTool = ToolType.Keep;            true }
                    Key.Three -> { activeTool = ToolType.Razor;           true }
                    Key.Four  -> { activeTool = ToolType.Shovel;          true }
                    Key.Five  -> { activeTool = ToolType.Trash;           true }
                    Key.Six   -> { activeTool = ToolType.RemoveFromTrash; true }
                    Key.Seven -> { activeTool = ToolType.Multi;           true }
                    Key.Eight -> { activeTool = ToolType.Information;     true }
                    // Bulk outlier operations
                    Key.A -> { frameViewModel?.keepAll();    true }
                    Key.K -> { frameViewModel?.removeAll();  true }
                    Key.U -> { frameViewModel?.clearUndecided(); true }
                    else -> false
                }
            },
    ) {
        when (interactionMode) {
            InteractionMode.Edit  -> EditModeView(
                sequenceViewModel = sequenceViewModel,
                frameViewModel = frameViewModel,
                activeTool = activeTool,
                onToolChange = { activeTool = it },
                onShowRenderVideo = { showRenderVideoDialog = true },
                onShowProcessingSettings = { showProcessingSettings = true },
            )
            InteractionMode.Scrub -> ScrubModeView(
                sequenceViewModel = sequenceViewModel,
                frameViewModel = frameViewModel,
                currentFrameIndex = currentFrameIndex,
            )
            InteractionMode.Grid  -> GridView(
                sequenceViewModel = sequenceViewModel,
                onFrameSelect = { idx -> sequenceViewModel.goToFrame(idx); appViewModel.setMode(InteractionMode.Edit) },
            )
        }

        if (showRenderVideoDialog) {
            RenderVideoDialog(
                sequenceViewModel = sequenceViewModel,
                onDismiss = { showRenderVideoDialog = false },
            )
        }
        if (showProcessingSettings) {
            ProcessingSettingsDialog(
                sequenceViewModel = sequenceViewModel,
                onDismiss = { showProcessingSettings = false },
            )
        }
    }
}

/** The full Edit mode layout: left panel · frame view · right panel, plus filmstrip. */
@Composable
private fun EditModeView(
    sequenceViewModel: SequenceViewModel,
    frameViewModel: FrameViewModel?,
    activeTool: ToolType,
    onToolChange: (ToolType) -> Unit,
    onShowRenderVideo: () -> Unit,
    onShowProcessingSettings: () -> Unit,
) {
    var leftExpanded by remember { mutableStateOf(true) }
    var rightExpanded by remember { mutableStateOf(true) }

    Column(Modifier.fillMaxSize()) {
        // Main 3-column row
        Row(Modifier.weight(1f).fillMaxWidth()) {
            if (leftExpanded) {
                LeftPanel(
                    sequenceViewModel = sequenceViewModel,
                    modifier = Modifier.width(220.dp).fillMaxHeight(),
                    onCollapse = { leftExpanded = false },
                    onShowProcessingSettings = onShowProcessingSettings,
                )
            }

            // Center: frame view + outlier overlay
            Box(Modifier.weight(1f).fillMaxHeight()) {
                frameViewModel?.let { fvm ->
                    FrameView(
                        frameViewModel = fvm,
                        activeTool = activeTool,
                    )
                } ?: run {
                    androidx.compose.material3.CircularProgressIndicator(
                        Modifier.align(androidx.compose.ui.Alignment.Center)
                    )
                }

                // Expand buttons
                if (!leftExpanded) {
                    ExpandButton(
                        Modifier.align(androidx.compose.ui.Alignment.CenterStart),
                        "›",
                        onClick = { leftExpanded = true },
                    )
                }
                if (!rightExpanded) {
                    ExpandButton(
                        Modifier.align(androidx.compose.ui.Alignment.CenterEnd),
                        "‹",
                        onClick = { rightExpanded = true },
                    )
                }
            }

            if (rightExpanded) {
                RightPanel(
                    frameViewModel = frameViewModel,
                    activeTool = activeTool,
                    onToolChange = onToolChange,
                    modifier = Modifier.width(220.dp).fillMaxHeight(),
                    onCollapse = { rightExpanded = false },
                    onShowRenderVideo = onShowRenderVideo,
                )
            }
        }

        // Bottom: filmstrip + scrubber
        BottomControls(
            sequenceViewModel = sequenceViewModel,
            modifier = Modifier.fillMaxWidth().height(100.dp),
        )
    }
}

/** Scrub mode: full-width frame view with slider below (no editing panels). */
@Composable
private fun ScrubModeView(
    sequenceViewModel: SequenceViewModel,
    frameViewModel: FrameViewModel?,
    currentFrameIndex: Int,
) {
    Column(Modifier.fillMaxSize()) {
        Box(Modifier.weight(1f).fillMaxWidth()) {
            frameViewModel?.let { FrameView(it, ToolType.None) }
        }
        BottomControls(sequenceViewModel = sequenceViewModel, Modifier.fillMaxWidth().height(80.dp))
    }
}

@Composable
private fun ExpandButton(modifier: Modifier, label: String, onClick: () -> Unit) {
    androidx.compose.material3.IconButton(onClick = onClick, modifier = modifier.padding(4.dp)) {
        androidx.compose.material3.Text(label, color = com.star.ui.theme.StarColors.textSecondary)
    }
}
