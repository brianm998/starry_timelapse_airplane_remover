package com.star.desktop.ui.sequence

import com.star.desktop.i18n.localized
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
import androidx.compose.runtime.setValue
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
        TopBar(app)

        Box(Modifier.weight(1f).fillMaxWidth()) {
            when (mode) {
                InteractionMode.SCRUB -> FrameImageView(
                    vm,
                    background = if (playing) StarColors.playbackBackground else StarColors.appBackground,
                )
                InteractionMode.EDIT -> Row(Modifier.fillMaxSize()) {
                    val leftShowing by vm.leftPanelShowing.collectAsState()
                    val rightShowing by vm.rightPanelShowing.collectAsState()
                    if (leftShowing) LeftPanel(app, vm)
                    else com.star.desktop.ui.components.CollapsedPanelRail({ vm.setLeftPanel(true) }, pointLeft = false)
                    val painting by vm.horizonPaintMode.collectAsState()
                    Box(Modifier.weight(1f).fillMaxSize()) {
                        if (painting) {
                            com.star.desktop.ui.sequence.edit.HorizonPainterView(app, vm)
                        } else {
                            com.star.desktop.ui.sequence.edit.FrameEditView(vm)
                        }
                    }
                    if (rightShowing) RightPanel(app, vm)
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
            // A frame that is not extracted yet has nothing to show: say how long it will be. Over the frame, so the tools that need the
            // original cannot be used on it; it goes when the frame lands.
            val extracted by vm.extractedFrames.collectAsState()
            val current by vm.currentIndex.collectAsState()
            if (mode != InteractionMode.GRID && extracted?.contains(current) == false) FrameWaitPanel(vm)
        }

        // how far extracting the video has got, while it is
        ExtractionStrip(vm)

        BottomControls(app, vm)

        // Bottom layout mirrors macOS ImageSequenceView: an optional filmstrip (edit/grid) above a
        // full-width scrub slider shown in every mode except grid — identical in scrub & edit.
        if (mode != InteractionMode.SCRUB && showFilmstrip) Filmstrip(vm)
        if (mode != InteractionMode.GRID) ScrubSlider(vm)
    }

    // The "re-run horizon refinement now or later?" question, here because the painter that raises it closes first.
    val refinementPrompt by vm.refinementPrompt.collectAsState()
    refinementPrompt?.let { com.star.desktop.ui.dialogs.HorizonRefinementPrompt(vm, it) }

    // Multi-frame outlier sheets (overlay the whole screen when active).
    val multiChoice by vm.multiChoice.collectAsState()
    multiChoice?.let { com.star.desktop.ui.dialogs.MultiChoiceSheet(vm, it) }
    val multiSelect by vm.multiSelect.collectAsState()
    multiSelect?.let { com.star.desktop.ui.dialogs.MultiSelectSheet(vm, it) }
}

/**
 * What is left of the top bar once the pickers have moved to the bottom left, where the gui has them (Q8): the engine badge, which only
 * the desktop has (it is the daemon's state), and no chip for painting the horizon (the right panel's button and the menu do that).
 */
@Composable
private fun TopBar(app: AppViewModel) {
    Row(
        Modifier.fillMaxWidth().background(StarColors.sidePanel.copy(alpha = 0.5f)).padding(horizontal = 12.dp, vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.End,
    ) {
        com.star.desktop.ui.app.EngineBadge(app)
    }
}

