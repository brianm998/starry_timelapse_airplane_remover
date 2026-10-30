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

@Composable
private fun TopBar(app: AppViewModel, vm: SequenceViewModel, mode: InteractionMode) {
    val viewMode by vm.viewMode.collectAsState()
    val playing by vm.isPlaying.collectAsState()
    val current by vm.currentIndex.collectAsState()
    val states by vm.frameStates.collectAsState()
    // The images the frame has: a pill for one it lacks is greyed out.
    var available by androidx.compose.runtime.remember { androidx.compose.runtime.mutableStateOf(setOf(FrameViewMode.VIEW_ORIGINAL)) }
    androidx.compose.runtime.LaunchedEffect(current, states[current]) { available = vm.availableViewModes(current).toSet() }
    Row(
        Modifier.fillMaxWidth().background(StarColors.sidePanel.copy(alpha = 0.5f)).padding(horizontal = 12.dp, vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        // The pickers are not there while the sequence plays (the gui hides them: there is nothing to choose between until it stops).
        // Mode segmented control
        if (!playing) com.star.desktop.ui.components.StarPicker(
            options = InteractionMode.entries,
            selected = mode,
            label = { localized(it.labelKey) },
            onSelect = { vm.setMode(it) },
        )
        Box(Modifier.weight(1f))
        // View-mode toggle
        if (!playing) com.star.desktop.ui.components.StarPicker(
            options = listOf(FrameViewMode.VIEW_ORIGINAL, FrameViewMode.VIEW_PROCESSED),
            selected = viewMode, // grid 'Show' may set SUBTRACTION/VALIDATION → no pill highlights (matches old chips)
            label = { localized(if (it == FrameViewMode.VIEW_PROCESSED) "ui.view_processed" else "ui.view_original") },
            onSelect = { vm.setViewMode(it) },
            isEnabled = { it in available },
        )
        if (mode == InteractionMode.EDIT) {
            val painting by vm.horizonPaintMode.collectAsState()
            Chip(localized("ui.paint_horizon_reference"), selected = painting) { vm.toggleHorizonPaint() }
        }
        // No Align chip here: the alignment window is already reachable from the Window menu
        // (StarMenuBar's "ui.alignment_2" item), so a duplicate top-bar button just adds confusion.
        // No Close chip either: closing this window already ends the session (Main.kt's
        // onCloseRequest = ::exitApplication), so a button that duplicates it isn't needed.
        // Engine status badge, laid out in the top bar (no longer a floating bottom-right overlay).
        com.star.desktop.ui.app.EngineBadge(app)
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
        Text(label, color = if (selected) Color.White else StarColors.textPrimary, fontSize = 13.sp) // match StarPicker label size
    }
}

