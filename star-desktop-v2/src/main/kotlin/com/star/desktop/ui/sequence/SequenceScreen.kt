package com.star.desktop.ui.sequence

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.star.desktop.domain.InteractionMode
import com.star.desktop.ui.app.AppViewModel
import com.star.desktop.ui.theme.StarColors
import com.star.proto.FrameViewMode

/**
 * The open-session shell (macOS `ImageSequenceView`): a mode router (edit / scrub / grid) over the
 * center frame view, with a top bar, bottom transport, and a filmstrip (edit/grid) or scrubber (scrub).
 */
@Composable
fun SequenceScreen(app: AppViewModel, vm: SequenceViewModel, modifier: Modifier = Modifier) {
    val mode by vm.mode.collectAsState()
    val showFilmstrip by vm.showFilmstrip.collectAsState()
    val playing by vm.isPlaying.collectAsState()

    Column(modifier.fillMaxSize().background(StarColors.appBackground)) {
        TopBar(app, vm, mode)

        Box(Modifier.weight(1f).fillMaxWidth()) {
            when (mode) {
                InteractionMode.SCRUB -> FrameImageView(
                    vm,
                    background = if (playing) StarColors.playbackBackground else StarColors.appBackground,
                )
                InteractionMode.EDIT -> Row(Modifier.fillMaxSize()) {
                    val leftShowing by vm.leftPanelShowing.collectAsState()
                    val rightShowing by vm.rightPanelShowing.collectAsState()
                    if (leftShowing) LeftPanel(vm, onProcessAll = { app.requestProcessAll() })
                    else com.star.desktop.ui.components.CollapsedPanelRail({ vm.setLeftPanel(true) }, pointLeft = false)
                    val painting by vm.horizonPaintMode.collectAsState()
                    Box(Modifier.weight(1f).fillMaxSize()) {
                        if (painting) {
                            com.star.desktop.ui.sequence.edit.HorizonPainterView(app, vm)
                        } else {
                            com.star.desktop.ui.sequence.edit.FrameEditView(vm)
                        }
                    }
                    if (rightShowing) RightPanel(vm)
                    else com.star.desktop.ui.components.CollapsedPanelRail({ vm.setRightPanel(true) }, pointLeft = true)
                }
                InteractionMode.GRID -> Row(Modifier.fillMaxSize()) {
                    val leftShowing by vm.leftPanelShowing.collectAsState()
                    val rightShowing by vm.rightPanelShowing.collectAsState()
                    if (leftShowing) com.star.desktop.ui.sequence.grid.GridLeftPanel(vm)
                    else com.star.desktop.ui.components.CollapsedPanelRail({ vm.setLeftPanel(true) }, pointLeft = false)
                    com.star.desktop.ui.sequence.grid.GridView(vm, Modifier.weight(1f).fillMaxSize())
                    if (rightShowing) com.star.desktop.ui.sequence.grid.GridRightPanel(vm)
                    else com.star.desktop.ui.components.CollapsedPanelRail({ vm.setRightPanel(true) }, pointLeft = true)
                }
            }
        }

        BottomControls(vm)

        when (mode) {
            InteractionMode.SCRUB -> ScrubSlider(vm)
            else -> if (showFilmstrip) Filmstrip(vm)
        }
    }

    // Multi-frame outlier sheets (overlay the whole screen when active).
    val multiChoice by vm.multiChoice.collectAsState()
    multiChoice?.let { com.star.desktop.ui.dialogs.MultiChoiceSheet(vm, it) }
    val multiSelect by vm.multiSelect.collectAsState()
    multiSelect?.let { com.star.desktop.ui.dialogs.MultiSelectSheet(vm, it) }
}

@Composable
private fun TopBar(app: AppViewModel, vm: SequenceViewModel, mode: InteractionMode) {
    val viewMode by vm.viewMode.collectAsState()
    Row(
        Modifier.fillMaxWidth().background(StarColors.sidePanel.copy(alpha = 0.5f)).padding(horizontal = 12.dp, vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        // Mode segmented control
        Row(horizontalArrangement = Arrangement.spacedBy(2.dp)) {
            InteractionMode.entries.forEach { m ->
                Chip(m.displayName, selected = m == mode) { vm.setMode(m) }
            }
        }
        Box(Modifier.weight(1f))
        // View-mode toggle
        Row(horizontalArrangement = Arrangement.spacedBy(2.dp)) {
            Chip("Original", selected = viewMode == FrameViewMode.VIEW_ORIGINAL) { vm.setViewMode(FrameViewMode.VIEW_ORIGINAL) }
            Chip("Processed", selected = viewMode == FrameViewMode.VIEW_PROCESSED) { vm.setViewMode(FrameViewMode.VIEW_PROCESSED) }
        }
        if (mode == InteractionMode.EDIT) {
            val painting by vm.horizonPaintMode.collectAsState()
            Chip("Paint Horizon", selected = painting) { vm.toggleHorizonPaint() }
        }
        Chip("Align", selected = false) { app.toggleAlignmentWindow() }
        Chip("Close", selected = false) { app.closeSession() }
    }
}

@Composable
private fun Chip(label: String, selected: Boolean, onClick: () -> Unit) {
    Box(
        Modifier
            .clip(RoundedCornerShape(5.dp))
            .background(if (selected) StarColors.accent else StarColors.cellDefault)
            .clickable(onClick = onClick)
            .padding(horizontal = 10.dp, vertical = 4.dp),
    ) {
        Text(label, color = if (selected) Color.White else StarColors.textPrimary, fontSize = 12.sp)
    }
}

