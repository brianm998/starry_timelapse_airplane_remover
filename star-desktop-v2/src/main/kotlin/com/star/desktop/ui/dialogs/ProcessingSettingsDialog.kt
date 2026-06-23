package com.star.desktop.ui.dialogs

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.star.desktop.ui.app.AppViewModel
import com.star.desktop.ui.components.GlyphButton
import com.star.desktop.ui.theme.StarColors
import com.star.desktop.ui.theme.StarShapes
import com.star.proto.CleanMethod
import com.star.proto.Config
import com.star.proto.DetectionType
import kotlinx.coroutines.launch

/**
 * Processing settings sheet (macOS `ProcessingSettingsView`). Edits the config fields the daemon's
 * `Sequence.UpdateConfig` actually applies (clean method, detection type, horizon, tripod,
 * concurrency); other config is read-only today and labeled as such.
 */
@Composable
fun ProcessingSettingsDialog(app: AppViewModel) {
    val scope = rememberCoroutineScope()
    val loaded by produceState<Config?>(null) { value = runCatching { app.sessions.getConfig() }.getOrNull() }

    Box(Modifier.fillMaxSize().background(StarColors.scrim).clickable(onClick = app::closeSettings), contentAlignment = Alignment.Center) {
        Column(
            modifier = Modifier
                .widthIn(max = 520.dp)
                .clip(StarShapes.card)
                .background(StarColors.prefsCard)
                .verticalScroll(rememberScrollState())
                .clickable(enabled = false) {}
                .padding(24.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            Text("Processing Settings", color = StarColors.textPrimary, fontWeight = FontWeight.SemiBold, fontSize = 18.sp)

            val cfg = loaded
            if (cfg == null) {
                Text("Loading…", color = StarColors.textSecondary, fontSize = 13.sp)
                return@Column
            }

            var clean by remember(cfg) { mutableStateOf(cfg.cleanMethod) }
            var detection by remember(cfg) { mutableStateOf(cfg.detectionType) }
            var horizon by remember(cfg) { mutableStateOf(cfg.horizonDetectionEnabled) }
            var tripod by remember(cfg) { mutableStateOf(cfg.tripodHeadWasMoving) }
            var concurrency by remember(cfg) { mutableStateOf(cfg.numberOfFramesToProcessConcurrently.coerceAtLeast(1)) }

            SettingGroup("Clean Method") {
                Segmented(
                    options = listOf(
                        CleanMethod.CLEAN_AUTOMATIC to "Automatic",
                        CleanMethod.CLEAN_AUTOMATIC_TRUE to "Auto-Selective",
                        CleanMethod.CLEAN_SELECTIVE to "Selective",
                    ),
                    selected = clean,
                    onSelect = { clean = it },
                )
                Text(
                    "Selective / Auto-Selective detect outlier groups you can review & edit. Automatic does not.",
                    color = StarColors.textDisabled, fontSize = 10.sp,
                )
            }

            SettingGroup("Detection Strength") {
                Segmented(
                    options = listOf(
                        DetectionType.DETECTION_MILD to "Mild",
                        DetectionType.DETECTION_STRONG to "Strong",
                        DetectionType.DETECTION_STRONGER to "Stronger",
                        DetectionType.DETECTION_EXCESSIVE to "Excessive",
                    ),
                    selected = detection,
                    onSelect = { detection = it },
                )
            }

            ToggleRow("Horizon detection", horizon) { horizon = it }
            ToggleRow("Tripod head was moving", tripod) { tripod = it }

            SettingGroup("Frames processed concurrently") {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    GlyphButton("−", "Fewer", { concurrency = (concurrency - 1).coerceAtLeast(1) }, size = 24, fontSize = 14)
                    Text("$concurrency", color = StarColors.textPrimary, fontSize = 14.sp)
                    GlyphButton("+", "More", { concurrency += 1 }, size = 24, fontSize = 14)
                }
            }

            Row(Modifier.fillMaxWidth().padding(top = 8.dp), horizontalArrangement = Arrangement.spacedBy(10.dp, Alignment.End)) {
                OutlinedButton(onClick = app::closeSettings) { Text("Cancel") }
                Button(
                    onClick = {
                        val updated = cfg.toBuilder()
                            .setCleanMethod(clean)
                            .setDetectionType(detection)
                            .setHorizonDetectionEnabled(horizon)
                            .setTripodHeadWasMoving(tripod)
                            .setNumberOfFramesToProcessConcurrently(concurrency)
                            .build()
                        scope.launch {
                            runCatching { app.sessions.updateConfig(updated) }
                            app.closeSettings()
                        }
                    },
                    colors = ButtonDefaults.buttonColors(containerColor = StarColors.accent),
                ) { Text("Save") }
            }
        }
    }
}

@Composable
private fun SettingGroup(title: String, content: @Composable () -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Text(title, color = StarColors.textSecondary, fontSize = 12.sp)
        content()
    }
}

@Composable
private fun <T> Segmented(options: List<Pair<T, String>>, selected: T, onSelect: (T) -> Unit) {
    Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
        options.forEach { (value, label) ->
            val isSel = value == selected
            Box(
                Modifier
                    .clip(RoundedCornerShape(5.dp))
                    .background(if (isSel) StarColors.accent else StarColors.cellDefault)
                    .clickable { onSelect(value) }
                    .padding(horizontal = 10.dp, vertical = 5.dp),
            ) { Text(label, color = if (isSel) Color.White else StarColors.textPrimary, fontSize = 11.sp) }
        }
    }
}

@Composable
private fun ToggleRow(label: String, value: Boolean, onChange: (Boolean) -> Unit) {
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.SpaceBetween) {
        Text(label, color = StarColors.textPrimary, fontSize = 13.sp)
        Switch(checked = value, onCheckedChange = onChange)
    }
}
