package com.star.desktop.ui.sequence

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
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
import com.star.desktop.domain.FrameState
import com.star.desktop.ui.components.VerticalStarPicker
import com.star.desktop.ui.theme.StarColors
import com.star.proto.FrameProcessingState
import com.star.proto.FrameViewMode
import com.star.desktop.i18n.localized

/** Left panel (macOS `LeftPanel`): processing controls, progress, and current-frame state. */
@Composable
fun LeftPanel(vm: SequenceViewModel, modifier: Modifier = Modifier, onProcessAll: () -> Unit = { vm.processAll() }) {
    val processing by vm.isProcessing.collectAsState()
    val rendering by vm.rendering.collectAsState()
    val renderProgress by vm.renderProgress.collectAsState()
    val states by vm.frameStates.collectAsState()
    val current by vm.currentIndex.collectAsState()
    val seqState by vm.sequenceState.collectAsState()
    val busy = processing || rendering

    val complete = states.values.count { it == FrameProcessingState.FPS_COMPLETE }
    val total = vm.frameCount

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

        Button(
            onClick = onProcessAll,
            enabled = !busy,
            colors = ButtonDefaults.buttonColors(containerColor = StarColors.accent),
            modifier = Modifier.fillMaxWidth(),
        ) { Text(localized("ui.process_all_frames_2")) }

        OutlinedButton(onClick = { vm.processRemaining() }, enabled = !busy, modifier = Modifier.fillMaxWidth()) {
            Text(localized("ui.process_remaining"))
        }
        OutlinedButton(onClick = { vm.processCurrent() }, enabled = !busy, modifier = Modifier.fillMaxWidth()) {
            Text(localized("ui.process_current_frame"))
        }
        OutlinedButton(onClick = { vm.reprocessCurrent() }, enabled = !busy, modifier = Modifier.fillMaxWidth()) {
            Text(localized("ui.reprocess_current_force"))
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
        OutlinedButton(onClick = { vm.renderAllFrames() }, enabled = !busy, modifier = Modifier.fillMaxWidth()) {
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

        LinearProgressIndicator(
            progress = { if (total > 0) complete.toFloat() / total else 0f },
            modifier = Modifier.fillMaxWidth().padding(top = 4.dp),
            color = StarColors.accent,
            trackColor = StarColors.cellDefault,
        )
        Text(
            localized("ui.n_of_m_complete", complete, total) + (seqState?.let { " · $it" } ?: ""),
            color = StarColors.textSecondary,
            fontSize = 11.sp,
        )

        // "Show:" — pick which available view mode the center frame displays (macOS frameModeView).
        ShowViewModes(vm)

        // Per-frame navigation now lives in the bottom scrub slider (shared with scrub mode), so the
        // old rounded-square frame grid was removed; just surface the current frame's state here.
        seqStateTooltip(states, current)
      }
      com.star.desktop.ui.components.PanelChevron("«", { vm.setLeftPanel(false) }, Modifier.padding(6.dp))
    }
}

/**
 * The "Show:" view-mode picker (macOS `LeftPanel.frameModeView`). Lists only the view modes that
 * actually exist for the current frame, so subtraction/validation/etc. appear as processing writes
 * them. Selecting one drives the shared [SequenceViewModel.viewMode] (kept in sync with the top bar).
 */
@Composable
private fun ShowViewModes(vm: SequenceViewModel) {
    val current by vm.currentIndex.collectAsState()
    val viewMode by vm.viewMode.collectAsState()
    val states by vm.frameStates.collectAsState()
    var available by remember { mutableStateOf<List<FrameViewMode>>(emptyList()) }
    // Recompute when the frame changes or its processing state advances (new previews may now exist).
    LaunchedEffect(current, states[current]) { available = vm.availableViewModes(current) }

    if (available.size <= 1) return // nothing meaningful to choose between
    Column(verticalArrangement = Arrangement.spacedBy(6.dp), modifier = Modifier.padding(top = 6.dp)) {
        Text(localized("ui.show_2"), color = StarColors.textSecondary, fontSize = 11.sp)
        VerticalStarPicker(
            options = available,
            selected = viewMode,
            label = { VIEW_MODE_LABELS[it] ?: it.name },
            onSelect = { vm.setViewMode(it) },
            modifier = Modifier.fillMaxWidth(),
        )
    }
}

private val VIEW_MODE_LABELS = mapOf(
    FrameViewMode.VIEW_ORIGINAL to "original frame",
    FrameViewMode.VIEW_PROCESSED to "final processed frame",
    FrameViewMode.VIEW_SUBTRACTION to "subtracted frame",
    FrameViewMode.VIEW_VALIDATION to "validation data",
)

@Composable
private fun seqStateTooltip(states: Map<Int, FrameProcessingState>, current: Int) {
    val s = states[current]
    if (s != null) {
        Text(
            "Frame ${current + 1}: ${FrameState.shortString(s)}",
            color = StarColors.textDisabled,
            fontSize = 10.sp,
            modifier = Modifier.padding(top = 4.dp),
        )
    }
}
