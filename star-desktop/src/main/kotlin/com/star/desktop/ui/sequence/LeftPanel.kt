package com.star.desktop.ui.sequence

import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.platform.testTag
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.star.desktop.domain.FrameStateCounts
import com.star.desktop.domain.ViewModes
import com.star.desktop.i18n.localized
import com.star.desktop.ui.app.AppViewModel
import com.star.desktop.ui.components.ExpandToggle
import com.star.desktop.ui.components.HoverTip
import com.star.desktop.ui.components.VerticalStarPicker
import com.star.desktop.ui.theme.StarColors
import com.star.proto.FrameViewMode

/**
 * Left panel (macOS `LeftPanel`): the images to show and how they are shown. The Processing and Render blocks that used to be here are menu
 * commands, as in the gui (owner decision D8): Actions has every one of them.
 */
@Composable
fun LeftPanel(app: AppViewModel, vm: SequenceViewModel, modifier: Modifier = Modifier) {
    val processing by vm.isProcessing.collectAsState()
    val states by vm.frameStates.collectAsState()

    val total = vm.frameCount
    val counts = remember(states, total) { FrameStateCounts(states, total) }

    Column(modifier.width(220.dp).fillMaxHeight().background(StarColors.sidePanel)) {
      Column(
        modifier = Modifier
            .weight(1f)
            .fillMaxWidth()
            .verticalScroll(rememberScrollState())
            .padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        // Not drawn: the progress bar is redundant with the processing screen, but the Gherkin desktop tests wait on this node.
        // What they wait on: "<complete>/<total>", with the run over (not locale text).
        Box(Modifier.size(0.dp).testTag("processing.progress").semantics { stateDescription = "${counts.complete}/$total/${if (processing) "running" else "idle"}" })

        // "Show:" — pick which image of the frame the center shows (macOS frameModeView).
        ShowViewModes(vm)

        // How the frame is shown and stepped through, under the images to show.
        CollapsibleSection(vm, RightPanelSection.DISPLAY, localized("ui.display"), localized("ui.section.display_help")) {
            DisplaySection(vm)
        }
      }
      com.star.desktop.ui.components.PanelChevron("«", { vm.setLeftPanel(false) }, Modifier.padding(6.dp))
    }
}

/**
 * The "Show:" list (macOS `frameModeView`): which image of the frame the center shows. It offers the images the frame has: the original,
 * the final and the painted horizon, or all of them once expanded. Selecting one drives the shared [SequenceViewModel.viewMode].
 */
@Composable
private fun ShowViewModes(vm: SequenceViewModel) {
    val current by vm.currentIndex.collectAsState()
    val viewMode by vm.viewMode.collectAsState()
    val states by vm.frameStates.collectAsState()
    val playing by vm.isPlaying.collectAsState()
    var available by remember { mutableStateOf<List<FrameViewMode>>(emptyList()) }
    var expanded by remember { mutableStateOf(false) }
    // Recompute when the frame changes or its processing state advances (new images may now exist).
    LaunchedEffect(current, states[current]) { available = vm.availableViewModes(current) }

    val shown = ViewModes.shown(available, expanded)
    Column(verticalArrangement = Arrangement.spacedBy(6.dp), modifier = Modifier.padding(top = 6.dp)) {
        Text(localized("ui.show_2"), color = StarColors.textSecondary, fontSize = 11.sp)
        if (shown.size > 1 || (shown.size == 1 && shown[0] != viewMode)) {
            VerticalStarPicker(
                options = shown,
                selected = viewMode,
                label = { ViewModes.longName(it) },
                onSelect = { if (!playing) vm.setViewMode(it) },
                modifier = Modifier.fillMaxWidth(),
            )
        }
        ExpandToggle(expanded, { expanded = !expanded })
    }
}
