package com.star.desktop.ui.sequence

import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.platform.testTag
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
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
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.star.desktop.domain.FrameState
import com.star.desktop.domain.FrameStateCounts
import com.star.desktop.domain.ProcessingButtonRole
import com.star.desktop.domain.ViewModes
import com.star.desktop.i18n.localized
import com.star.desktop.ui.app.AppViewModel
import com.star.desktop.ui.components.DeviationChart
import com.star.desktop.ui.components.ExpandToggle
import com.star.desktop.ui.components.HoverTip
import com.star.desktop.ui.components.VerticalStarPicker
import com.star.desktop.ui.theme.StarColors
import com.star.proto.FrameProcessingState
import com.star.proto.FrameViewMode

/** Left panel (macOS `LeftPanel`): processing controls, progress, and the images to show. */
@Composable
fun LeftPanel(app: AppViewModel, vm: SequenceViewModel, modifier: Modifier = Modifier) {
    val processing by vm.isProcessing.collectAsState()
    val rendering by vm.rendering.collectAsState()
    val renderProgress by vm.renderProgress.collectAsState()
    val states by vm.frameStates.collectAsState()
    val seqState by vm.sequenceState.collectAsState()
    val refinementPending by vm.refinementPending.collectAsState()
    val busy = processing || rendering

    val total = vm.frameCount
    val counts = remember(states, total) { FrameStateCounts(states, total) }
    val role = ProcessingButtonRole.current(processing, rendering, counts, total, refinementPending)

    Column(modifier.width(220.dp).fillMaxHeight().background(StarColors.sidePanel)) {
      Column(
        modifier = Modifier
            .weight(1f)
            .fillMaxWidth()
            .verticalScroll(rememberScrollState())
            .padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Text(localized("ui.processing"), color = StarColors.textPrimary, fontWeight = FontWeight.SemiBold, fontSize = 13.sp)

        // Status while a run is going, which puts the processing screen back; otherwise it opens the settings, where a run is started.
        when (role) {
            ProcessingButtonRole.Status -> HoverTip(localized("ui.show_the_processing_status_again")) {
                Button(
                    onClick = { vm.reopenProcessingModal() },
                    colors = ButtonDefaults.buttonColors(containerColor = StarColors.accent),
                    modifier = Modifier.fillMaxWidth(),
                ) { Text(localized("ui.status")) }
            }
            is ProcessingButtonRole.Process -> HoverTip(localized("ui.choose_settings_and_process_these_frames")) {
                Button(
                    onClick = { app.openSettings() },
                    enabled = role.enabled,
                    colors = ButtonDefaults.buttonColors(containerColor = StarColors.accent),
                    modifier = Modifier.fillMaxWidth().testTag("process.frames"),
                ) { Text(localized("ui.process_frames")) }
            }
        }

        // Enabled once every frame is complete: there is nothing to render a video from before that.
        Button(
            onClick = { app.openRenderVideo() },
            enabled = counts.complete == total && !busy,
            colors = ButtonDefaults.buttonColors(containerColor = StarColors.accent),
            modifier = Modifier.fillMaxWidth(),
        ) { Text(localized("ui.render_video_from_n_frames_lower", total), fontSize = 12.sp) }

        OutlinedButton(onClick = { vm.processRemaining() }, enabled = !busy, modifier = Modifier.fillMaxWidth()) {
            Text(localized("ui.process_frames_from_here_to_the_end"))
        }
        OutlinedButton(onClick = { vm.processCurrent() }, enabled = !busy, modifier = Modifier.fillMaxWidth()) {
            Text(localized("ui.process_current_frame"))
        }
        OutlinedButton(onClick = { vm.reprocessCurrent() }, enabled = !busy, modifier = Modifier.fillMaxWidth()) {
            Text(localized("ui.reprocess_current_force"))
        }
        OutlinedButton(onClick = { vm.findOutliersCurrent() }, enabled = !busy, modifier = Modifier.fillMaxWidth()) {
            Text(localized("ui.find_outliers_for_this_frame"))
        }

        if (processing) {
            OutlinedButton(
                onClick = { vm.cancelProcessing() },
                colors = ButtonDefaults.outlinedButtonColors(contentColor = StarColors.red),
                modifier = Modifier.fillMaxWidth(),
            ) { Text(localized("ui.cancel")) }
        }

        Text(localized("ui.render"), color = StarColors.textSecondary, fontSize = 11.sp, modifier = Modifier.padding(top = 6.dp))
        OutlinedButton(onClick = { vm.renderCurrentFrame() }, enabled = !busy, modifier = Modifier.fillMaxWidth()) {
            Text(localized("ui.render_current_frame"))
        }
        OutlinedButton(onClick = { vm.renderAllFrames() }, enabled = !busy, modifier = Modifier.fillMaxWidth().testTag("render.all.frames")) {
            Text(localized("ui.render_all_frames"))
        }
        if (rendering) {
            LinearProgressIndicator(
                progress = { renderProgress ?: 0f },
                modifier = Modifier.fillMaxWidth(),
                color = StarColors.accent,
                trackColor = StarColors.cellDefault,
            )
        }

        ProcessingProgressBar(counts, Modifier.padding(top = 4.dp))
        Text(
            localized("ui.n_of_m_complete", counts.complete, total) + (seqState?.let { " · $it" } ?: ""),
            color = StarColors.textSecondary,
            fontSize = 11.sp,
            // What the Gherkin desktop tests wait on: "<complete>/<total>", with the run over (not locale text).
            modifier = Modifier.testTag("processing.progress").semantics { stateDescription = "${counts.complete}/$total/${if (processing) "running" else "idle"}" },
        )

        // How far the star alignment moved the pictures, filling in as frames align (macOS draws it here at 200 by 200).
        AlignmentThumbnail(vm)

        ProcessingStats(counts)

        // "Show:" — pick which image of the frame the center shows (macOS frameModeView).
        ShowViewModes(vm)
      }
      com.star.desktop.ui.components.PanelChevron("«", { vm.setLeftPanel(false) }, Modifier.padding(6.dp))
    }
}

/** The star deviation chart in the panel's width, with its Height slider; nothing until some frame has aligned. */
@Composable
private fun AlignmentThumbnail(vm: SequenceViewModel) {
    val data by vm.alignment.collectAsState()
    val current by vm.currentIndex.collectAsState()
    val alignment = data
    if (alignment != null && alignment.hasStar) {
        DeviationChart(alignment.starPoints, vm.frameCount, current, vm::setCurrentIndex, chartHeight = 170.dp, compact = true)
    }
}

/**
 * The progress bar under the buttons (macOS `ProcessingProgressBarView`): finished frames in green, then the ones being worked on in
 * yellow, then the ones not started in gray, each as wide as its share of the sequence.
 */
@Composable
private fun ProcessingProgressBar(counts: FrameStateCounts, modifier: Modifier = Modifier) {
    val (done, working, left) = counts.fractions()
    Row(modifier.fillMaxWidth().height(10.dp).clip(RoundedCornerShape(4.dp)).background(StarColors.cellDefault)) {
        if (done > 0f) Box(Modifier.weight(done).fillMaxHeight().background(StarColors.green))
        if (working > 0f) Box(Modifier.weight(working).fillMaxHeight().background(StarColors.yellow))
        if (left > 0f) Box(Modifier.weight(left).fillMaxHeight().background(StarColors.gray))
    }
}

/**
 * How many frames are in each state (macOS `processingStateView`): untouched, being worked on, and finished, or every state there is
 * when expanded. A state no frame is in is gray.
 */
@Composable
private fun ProcessingStats(counts: FrameStateCounts) {
    var expanded by remember { mutableStateOf(false) }
    Column(Modifier.padding(top = 4.dp)) {
        Text(localized("ui.processing_stats"), color = StarColors.textPrimary, fontSize = 12.sp)
        Column(Modifier.padding(top = 4.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            if (expanded) {
                for (state in FrameProcessingState.entries.filter { it != FrameProcessingState.UNRECOGNIZED }) {
                    StatRow(counts[state], FrameState.message(state))
                }
            } else {
                StatRow(counts.unprocessed, FrameState.message(FrameProcessingState.FPS_UNPROCESSED))
                StatRow(counts.working, localized("ui.processing_2"))
                StatRow(counts.complete, FrameState.message(FrameProcessingState.FPS_COMPLETE))
            }
        }
        ExpandToggle(expanded, { expanded = !expanded })
    }
}

@Composable
private fun StatRow(count: Int, label: String) {
    val color = if (count == 0) StarColors.gray else StarColors.white
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Text("$count", color = color, fontSize = 11.sp, modifier = Modifier.width(36.dp))
        Text(label, color = color, fontSize = 11.sp)
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
