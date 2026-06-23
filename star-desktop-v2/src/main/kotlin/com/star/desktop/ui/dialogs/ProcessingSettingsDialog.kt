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
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.snapshots.SnapshotStateMap
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
            var showExpert by remember { mutableStateOf(false) }
            // Expert-field edits: bools and raw text (parsed on save) keyed by field label.
            val boolEdits = remember(cfg) { androidx.compose.runtime.mutableStateMapOf<String, Boolean>() }
            val textEdits = remember(cfg) { androidx.compose.runtime.mutableStateMapOf<String, String>() }

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

            ToggleRow(if (showExpert) "Hide Expert Settings" else "Show Expert Settings", showExpert) { showExpert = it }
            if (showExpert) {
                ExpertGroup("Alignment", ALIGNMENT_FIELDS, cfg, boolEdits, textEdits)
                ExpertGroup("Horizon", HORIZON_FIELDS, cfg, boolEdits, textEdits)
                ExpertGroup("Memory", MEMORY_FIELDS, cfg, boolEdits, textEdits)
            }

            Row(Modifier.fillMaxWidth().padding(top = 8.dp), horizontalArrangement = Arrangement.spacedBy(10.dp, Alignment.End)) {
                OutlinedButton(onClick = app::closeSettings) { Text("Cancel") }
                Button(
                    onClick = {
                        val b = cfg.toBuilder()
                            .setCleanMethod(clean)
                            .setDetectionType(detection)
                            .setHorizonDetectionEnabled(horizon)
                            .setTripodHeadWasMoving(tripod)
                            .setNumberOfFramesToProcessConcurrently(concurrency)
                        // Apply expert edits (cfg already carries current values; only changed ones differ).
                        (ALIGNMENT_FIELDS + HORIZON_FIELDS + MEMORY_FIELDS).forEach { f ->
                            when (f) {
                                is BoolField -> boolEdits[f.label]?.let { f.set(b, it) }
                                is IntField -> textEdits[f.label]?.toIntOrNull()?.let { f.set(b, it.coerceIn(f.min, f.max)) }
                                is DoubleField -> textEdits[f.label]?.toDoubleOrNull()?.let { f.set(b, it) }
                            }
                        }
                        val updated = b.build()
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

// ---- Expert settings (StarCore Config expert fields, data-driven) ----

private sealed interface ExpertField { val label: String }
private class IntField(override val label: String, val get: (Config) -> Int, val set: (Config.Builder, Int) -> Config.Builder, val min: Int, val max: Int) : ExpertField
private class DoubleField(override val label: String, val get: (Config) -> Double, val set: (Config.Builder, Double) -> Config.Builder) : ExpertField
private class BoolField(override val label: String, val get: (Config) -> Boolean, val set: (Config.Builder, Boolean) -> Config.Builder) : ExpertField

private val ALIGNMENT_FIELDS: List<ExpertField> = listOf(
    IntField("Neighbor frames", { it.numberAlignedNeighborFrames }, { b, v -> b.setNumberAlignedNeighborFrames(v) }, 1, 1000),
    IntField("Static neighbor frames", { it.numberStaticNeighborFrames }, { b, v -> b.setNumberStaticNeighborFrames(v) }, 1, 1000),
    IntField("Max keypoints", { it.alignmentMaxKeypoints }, { b, v -> b.setAlignmentMaxKeypoints(v) }, 4, 10000),
    IntField("Ground horizon extension", { it.alignmentGroundHorizonExtension }, { b, v -> b.setAlignmentGroundHorizonExtension(v) }, 0, 10000),
    IntField("Sky horizon extension", { it.alignmentSkyHorizonExtension }, { b, v -> b.setAlignmentSkyHorizonExtension(v) }, 0, 10000),
    IntField("Base image dilate size", { it.alignmentBaseImageDilateSize }, { b, v -> b.setAlignmentBaseImageDilateSize(v) }, 4, 10000),
    IntField("Base image threshold", { it.alignmentBaseImageThresholdValue }, { b, v -> b.setAlignmentBaseImageThresholdValue(v) }, 1, 255),
    DoubleField("Homography smoothing ε", { it.homographySmoothingEpsilon }, { b, v -> b.setHomographySmoothingEpsilon(v) }),
    BoolField("Allow earth alignment", { it.allowEarthAlignment }, { b, v -> b.setAllowEarthAlignment(v) }),
    BoolField("Write debug images", { it.alignmentWriteDebugImages }, { b, v -> b.setAlignmentWriteDebugImages(v) }),
)

private val HORIZON_FIELDS: List<ExpertField> = listOf(
    IntField("Strip width", { it.horizonStripWidth }, { b, v -> b.setHorizonStripWidth(v) }, 1, 8000),
    BoolField("Canny edge detection", { it.useCannyForHorizonDetection }, { b, v -> b.setUseCannyForHorizonDetection(v) }),
    DoubleField("Canny min threshold", { it.cannyMinThreshold }, { b, v -> b.setCannyMinThreshold(v) }),
    DoubleField("Canny max threshold", { it.cannyMaxThreshold }, { b, v -> b.setCannyMaxThreshold(v) }),
    BoolField("Canny L2 gradient", { it.cannyUseL2Gradient }, { b, v -> b.setCannyUseL2Gradient(v) }),
    IntField("Horizon shift", { it.horizonVerticalShiftAmount }, { b, v -> b.setHorizonVerticalShiftAmount(v) }, 0, 300),
    BoolField("Reference horizon smoothing", { it.useReferenceHorizonSmoothing }, { b, v -> b.setUseReferenceHorizonSmoothing(v) }),
    IntField("Smoothing max distance", { it.referenceHorizonSmoothingMaxDistance }, { b, v -> b.setReferenceHorizonSmoothingMaxDistance(v) }, 1, 10000),
    BoolField("Brightness refinement", { it.useReferenceHorizonBrightnessRefinement }, { b, v -> b.setUseReferenceHorizonBrightnessRefinement(v) }),
    IntField("Refinement search radius", { it.referenceHorizonBrightnessRefinementSearchRadius }, { b, v -> b.setReferenceHorizonBrightnessRefinementSearchRadius(v) }, 1, 10000),
    IntField("Refinement hist buckets", { it.referenceHorizonBrightnessRefinementHistBuckets }, { b, v -> b.setReferenceHorizonBrightnessRefinementHistBuckets(v) }, 2, 65536),
    IntField("Neighborhood size", { it.referenceHorizonNeighborhoodSize }, { b, v -> b.setReferenceHorizonNeighborhoodSize(v) }, 1, 99),
    BoolField("Spike removal", { it.horizonSpikeRemovalEnabled }, { b, v -> b.setHorizonSpikeRemovalEnabled(v) }),
    IntField("Spike max width", { it.horizonSpikeMaxWidth }, { b, v -> b.setHorizonSpikeMaxWidth(v) }, 1, 500),
    DoubleField("Spike max deviation", { it.horizonSpikeMaxDeviationFraction }, { b, v -> b.setHorizonSpikeMaxDeviationFraction(v) }),
    IntField("Spike window half", { it.horizonSpikeWindowHalf }, { b, v -> b.setHorizonSpikeWindowHalf(v) }, 10, 2000),
)

private val MEMORY_FIELDS: List<ExpertField> = listOf(
    IntField("Keypoint mem ×", { it.keypointMemoryMultiplier }, { b, v -> b.setKeypointMemoryMultiplier(v) }, 1, 200),
    IntField("Outlier mem ×", { it.outlierMemoryMultiplier }, { b, v -> b.setOutlierMemoryMultiplier(v) }, 1, 50),
    IntField("Merge mem ×", { it.mergeMemoryMultiplier }, { b, v -> b.setMergeMemoryMultiplier(v) }, 1, 50),
)

@Composable
private fun ExpertGroup(
    title: String,
    fields: List<ExpertField>,
    cfg: Config,
    boolEdits: SnapshotStateMap<String, Boolean>,
    textEdits: SnapshotStateMap<String, String>,
) {
    SettingGroup(title) {
        fields.forEach { f ->
            when (f) {
                is BoolField -> ToggleRow(f.label, boolEdits[f.label] ?: f.get(cfg)) { boolEdits[f.label] = it }
                is IntField -> NumberRow(f.label, textEdits[f.label] ?: f.get(cfg).toString()) {
                    textEdits[f.label] = it.filter { c -> c.isDigit() }
                }
                is DoubleField -> NumberRow(f.label, textEdits[f.label] ?: f.get(cfg).toString()) {
                    textEdits[f.label] = it.filter { c -> c.isDigit() || c == '.' }
                }
            }
        }
    }
}

@Composable
private fun NumberRow(label: String, value: String, onChange: (String) -> Unit) {
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(label, color = StarColors.textPrimary, fontSize = 12.sp, modifier = Modifier.weight(1f))
        OutlinedTextField(
            value = value,
            onValueChange = onChange,
            singleLine = true,
            textStyle = androidx.compose.ui.text.TextStyle(fontSize = 12.sp),
            modifier = Modifier.widthIn(max = 110.dp),
        )
    }
}
