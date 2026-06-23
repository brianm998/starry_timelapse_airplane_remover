package com.star.desktop.ui.sequence

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
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
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.star.desktop.domain.FrameState
import com.star.desktop.ui.theme.StarColors
import com.star.proto.FrameProcessingState

/** Left panel (macOS `LeftPanel`): processing controls, progress, and a per-frame state grid. */
@OptIn(ExperimentalLayoutApi::class)
@Composable
fun LeftPanel(vm: SequenceViewModel, modifier: Modifier = Modifier) {
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
        Text("Processing", color = StarColors.textPrimary, fontWeight = FontWeight.SemiBold, fontSize = 13.sp)

        Button(
            onClick = { vm.processAll() },
            enabled = !busy,
            colors = ButtonDefaults.buttonColors(containerColor = StarColors.accent),
            modifier = Modifier.fillMaxWidth(),
        ) { Text("Process All Frames") }

        OutlinedButton(onClick = { vm.processRemaining() }, enabled = !busy, modifier = Modifier.fillMaxWidth()) {
            Text("Process Remaining")
        }
        OutlinedButton(onClick = { vm.processCurrent() }, enabled = !busy, modifier = Modifier.fillMaxWidth()) {
            Text("Process Current Frame")
        }

        if (processing) {
            OutlinedButton(
                onClick = { vm.cancelProcessing() },
                colors = ButtonDefaults.outlinedButtonColors(contentColor = StarColors.red),
                modifier = Modifier.fillMaxWidth(),
            ) { Text("Cancel") }
        }

        Text("Render", color = StarColors.textSecondary, fontSize = 11.sp, modifier = Modifier.padding(top = 6.dp))
        OutlinedButton(onClick = { vm.renderCurrentFrame() }, enabled = !busy, modifier = Modifier.fillMaxWidth()) {
            Text("Render Current Frame")
        }
        OutlinedButton(onClick = { vm.renderAllFrames() }, enabled = !busy, modifier = Modifier.fillMaxWidth()) {
            Text("Render All Frames")
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
            "$complete / $total complete" + (seqState?.let { " · $it" } ?: ""),
            color = StarColors.textSecondary,
            fontSize = 11.sp,
        )

        Text("Frames", color = StarColors.textSecondary, fontSize = 11.sp, modifier = Modifier.padding(top = 6.dp))
        FlowRow(horizontalArrangement = Arrangement.spacedBy(3.dp), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            for (i in 0 until total) {
                val s = states[i]
                val color = when {
                    s == FrameProcessingState.FPS_COMPLETE -> StarColors.green
                    s == null || s == FrameProcessingState.FPS_UNPROCESSED -> StarColors.cellDefault
                    else -> StarColors.yellow
                }
                Box(
                    Modifier
                        .size(14.dp)
                        .clip(RoundedCornerShape(2.dp))
                        .background(if (i == current) StarColors.accent else color)
                        .clickable { vm.setCurrentIndex(i) },
                    contentAlignment = Alignment.Center,
                ) {}
            }
        }
        seqStateTooltip(states, current)
      }
      com.star.desktop.ui.components.PanelChevron("«", { vm.setLeftPanel(false) }, Modifier.padding(6.dp))
    }
}

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
