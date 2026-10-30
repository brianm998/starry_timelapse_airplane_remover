package com.star.desktop.ui.dialogs

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Slider
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.star.desktop.domain.CustomLimits
import com.star.desktop.i18n.localized
import com.star.desktop.ui.app.AppViewModel
import com.star.desktop.ui.components.defaultAction
import com.star.desktop.ui.components.modalScrim
import com.star.desktop.ui.theme.StarColors

/**
 * Every limit behind the Custom profile, as editable fields (macOS `ResourceCustomLimitsView`): the pipeline depth cap, the memory budget,
 * how many CPU, GPU and disk operations run at once, how much of the time the GPU may be busy, and the thread and disk priorities. Opened
 * with the values of the profile it was opened from; each change reaches the run in progress as it is made, so the sliders send when they
 * are let go. Done (or Return, or Esc) closes it.
 */
@Composable
fun ResourceCustomLimitsDialog(app: AppViewModel) {
    val session by app.sessions.session.collectAsState()
    val config = session?.config
    // Starts as what the session holds, and is taken again whenever that changes (the profile switch that opened this lands after it does).
    var limits by remember(config) { mutableStateOf(config?.let(CustomLimits::of)) }
    val close = { app.closeCustomLimits() }
    fun change(next: CustomLimits) {
        limits = next
        app.setCustomLimits(next)
    }

    Box(
        Modifier.fillMaxSize().background(Color(0.5f, 0.5f, 0.5f, 0.5f)).modalScrim().defaultAction({ close() }, onEscape = close),
        contentAlignment = Alignment.Center,
    ) {
        Column(
            Modifier.widthIn(max = 460.dp).clip(RoundedCornerShape(20.dp)).background(StarColors.prefsCard).clickable(enabled = false) {}.padding(24.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text(localized("ui.use_custom_title"), color = StarColors.white, fontWeight = FontWeight.SemiBold, fontSize = 22.sp)
            limits?.let { l ->
                StepperRow(localized("ui.use_custom_pipeline_depth"), l.pipelineDepth, CustomLimits.PIPELINE_DEPTH) { change(l.copy(pipelineDepth = it)) }
                SliderRow(localized("ui.use_custom_memory"), l.memoryFraction, CustomLimits.MEMORY_FRACTION, { limits = l.copy(memoryFraction = it) }) {
                    change(l.copy(memoryFraction = it))
                }
                StepperRow(localized("ui.use_custom_cpu"), l.cpuWidth, CustomLimits.CPU_WIDTH) { change(l.copy(cpuWidth = it)) }
                StepperRow(localized("ui.use_custom_gpu"), l.gpuWidth, CustomLimits.GPU_WIDTH) { change(l.copy(gpuWidth = it)) }
                SliderRow(localized("ui.use_custom_gpu_duty"), l.gpuDutyCycle, CustomLimits.GPU_DUTY_CYCLE, { limits = l.copy(gpuDutyCycle = it) }) {
                    change(l.copy(gpuDutyCycle = it))
                }
                StepperRow(localized("ui.use_custom_disk"), l.diskStreams, CustomLimits.DISK_STREAMS) { change(l.copy(diskStreams = it)) }
                ChoiceRow(localized("ui.use_custom_qos"), CustomLimits.QOS, l.qos) { change(l.copy(qos = it)) }
                ChoiceRow(localized("ui.use_custom_io"), CustomLimits.IO_POLICY, l.ioPolicy) { change(l.copy(ioPolicy = it)) }
            }
            Row(Modifier.fillMaxWidth()) {
                Spacer(Modifier.weight(1f))
                Button(onClick = close, colors = ButtonDefaults.buttonColors(containerColor = StarColors.accent)) { Text(localized("ui.use_custom_done")) }
            }
        }
    }
}

/** "Label: value" with a minus and a plus, held to [range]. */
@Composable
private fun StepperRow(label: String, value: Int, range: IntRange, onChange: (Int) -> Unit) {
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Text("$label: $value", color = StarColors.white, fontSize = 13.sp, modifier = Modifier.weight(1f))
        StepButton("−", enabled = value > range.first) { onChange((value - 1).coerceIn(range)) }
        Spacer(Modifier.width(4.dp))
        StepButton("+", enabled = value < range.last) { onChange((value + 1).coerceIn(range)) }
    }
}

@Composable
private fun StepButton(text: String, enabled: Boolean, onClick: () -> Unit) {
    Text(
        text, color = if (enabled) Color.White else StarColors.textDisabled, fontSize = 14.sp,
        modifier = Modifier.clip(RoundedCornerShape(5.dp)).background(StarColors.cellDefault).clickable(enabled = enabled, onClick = onClick).padding(horizontal = 10.dp, vertical = 2.dp),
    )
}

/** "Label: value" over a slider that shows the value as it moves and sends it when it is let go. */
@Composable
private fun SliderRow(label: String, value: Double, range: ClosedFloatingPointRange<Double>, onMove: (Double) -> Unit, onSet: (Double) -> Unit) {
    var latest by remember(value) { mutableStateOf(value) }
    Column {
        Text("$label: ${"%.2f".format(latest)}", color = StarColors.white, fontSize = 13.sp)
        Slider(
            value = latest.toFloat(),
            onValueChange = { latest = it.toDouble(); onMove(latest) },
            onValueChangeFinished = { onSet(latest) },
            valueRange = range.start.toFloat()..range.endInclusive.toFloat(),
            modifier = Modifier.fillMaxWidth(),
        )
    }
}

/** A row of choices, one of which is [selected]; [options] are the daemon's names with their names in the catalogue. */
@Composable
private fun ChoiceRow(label: String, options: List<Pair<String, String>>, selected: String, onSelect: (String) -> Unit) {
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Text(label, color = StarColors.white, fontSize = 13.sp, modifier = Modifier.weight(1f))
        Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
            for ((name, key) in options) {
                val isSelected = name == selected
                Text(
                    localized(key), color = if (isSelected) Color.White else StarColors.textPrimary, fontSize = 11.sp,
                    modifier = Modifier.clip(RoundedCornerShape(5.dp)).background(if (isSelected) StarColors.accent else StarColors.cellDefault)
                        .clickable { onSelect(name) }.padding(horizontal = 8.dp, vertical = 3.dp),
                )
            }
        }
    }
}
