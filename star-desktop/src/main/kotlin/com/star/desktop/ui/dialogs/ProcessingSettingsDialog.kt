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
import com.star.desktop.engine.EngineStatus
import com.star.desktop.ui.app.AppViewModel
import com.star.desktop.ui.components.GlyphButton
import com.star.desktop.ui.theme.StarColors
import com.star.desktop.ui.theme.StarShapes
import com.star.proto.CleanMethod
import com.star.proto.Config
import com.star.proto.DetectionType
import kotlinx.coroutines.launch
import com.star.desktop.i18n.localized

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
            Text(localized("ui.processing_settings"), color = StarColors.textPrimary, fontWeight = FontWeight.SemiBold, fontSize = 18.sp)

            val cfg = loaded
            if (cfg == null) {
                Text(localized("ui.loading"), color = StarColors.textSecondary, fontSize = 13.sp)
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
                    localized("ui.selective_auto_selective_detect_outlier"),
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
                // Only to word the "needs a newer engine" note; whether a field is supported
                // is decided by its presence in the config the daemon sent, not by this.
                val daemonVersion = (app.engineStatus.value as? EngineStatus.Connected)?.daemonVersion
                ExpertGroup("Alignment", ALIGNMENT_FIELDS, cfg, boolEdits, textEdits, daemonVersion)
                ExpertGroup("Horizon", HORIZON_FIELDS, cfg, boolEdits, textEdits, daemonVersion)
                ExpertGroup("Memory", MEMORY_FIELDS, cfg, boolEdits, textEdits, daemonVersion)
            }

            Row(Modifier.fillMaxWidth().padding(top = 8.dp), horizontalArrangement = Arrangement.spacedBy(10.dp, Alignment.End)) {
                OutlinedButton(onClick = app::closeSettings) { Text(localized("ui.cancel")) }
                Button(
                    onClick = {
                        val b = cfg.toBuilder()
                            .setCleanMethod(clean)
                            .setDetectionType(detection)
                            .setHorizonDetectionEnabled(horizon)
                            .setTripodHeadWasMoving(tripod)
                            .setNumberOfFramesToProcessConcurrently(concurrency)
                        // Apply expert edits (cfg already carries current values; only changed ones differ).
                        // Unsupported fields are skipped: they render as read-only so there
                        // should be no edit to apply, and sending one to a daemon that does
                        // not know the field would be a silent no-op at best.
                        (ALIGNMENT_FIELDS + HORIZON_FIELDS + MEMORY_FIELDS).filter { it.has(cfg) }.forEach { f ->
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
                ) { Text(localized("ui.save")) }
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

/// `has` answers "did the daemon send this field?".
///
/// Every expert field is `optional` in the proto, and a current daemon fills all of them
/// on the way out, so an absent field means the daemon predates it. Without this check the
/// row would render the proto3 default — 0 — and read as a real setting. That is actively
/// misleading for the fields where 0 means something: 0 merge streaming MB reads as "never
/// stream", 0 horizon floor as "no floor".
///
/// Presence rather than comparing `daemonVersion` against a table of which version added
/// which field: it is exact, it is per field, and it needs no maintenance as fields are
/// added. The version string is only used to word the message. (Reflection would be the
/// other option, but the client uses protobuf-lite, which has no descriptors.)
internal sealed interface ExpertField {
    val label: String
    val has: (Config) -> Boolean
}
internal class IntField(override val label: String, val get: (Config) -> Int, val set: (Config.Builder, Int) -> Config.Builder, val min: Int, val max: Int, override val has: (Config) -> Boolean) : ExpertField
internal class DoubleField(override val label: String, val get: (Config) -> Double, val set: (Config.Builder, Double) -> Config.Builder, override val has: (Config) -> Boolean) : ExpertField
internal class BoolField(override val label: String, val get: (Config) -> Boolean, val set: (Config.Builder, Boolean) -> Config.Builder, override val has: (Config) -> Boolean) : ExpertField

internal val ALIGNMENT_FIELDS: List<ExpertField> = listOf(
    IntField("Neighbor frames", { it.numberAlignedNeighborFrames }, { b, v -> b.setNumberAlignedNeighborFrames(v) }, 1, 1000, { it.hasNumberAlignedNeighborFrames() }),
    IntField("Static neighbor frames", { it.numberStaticNeighborFrames }, { b, v -> b.setNumberStaticNeighborFrames(v) }, 1, 1000, { it.hasNumberStaticNeighborFrames() }),
    IntField("Max keypoints", { it.alignmentMaxKeypoints }, { b, v -> b.setAlignmentMaxKeypoints(v) }, 4, 10000, { it.hasAlignmentMaxKeypoints() }),
    IntField("Ground horizon extension", { it.alignmentGroundHorizonExtension }, { b, v -> b.setAlignmentGroundHorizonExtension(v) }, 0, 10000, { it.hasAlignmentGroundHorizonExtension() }),
    IntField("Sky horizon extension", { it.alignmentSkyHorizonExtension }, { b, v -> b.setAlignmentSkyHorizonExtension(v) }, 0, 10000, { it.hasAlignmentSkyHorizonExtension() }),
    IntField("Base image dilate size", { it.alignmentBaseImageDilateSize }, { b, v -> b.setAlignmentBaseImageDilateSize(v) }, 4, 10000, { it.hasAlignmentBaseImageDilateSize() }),
    IntField("Base image threshold", { it.alignmentBaseImageThresholdValue }, { b, v -> b.setAlignmentBaseImageThresholdValue(v) }, 1, 255, { it.hasAlignmentBaseImageThresholdValue() }),
    DoubleField("Homography smoothing ε", { it.homographySmoothingEpsilon }, { b, v -> b.setHomographySmoothingEpsilon(v) }, { it.hasHomographySmoothingEpsilon() }),
    BoolField("Allow earth alignment", { it.allowEarthAlignment }, { b, v -> b.setAllowEarthAlignment(v) }, { it.hasAllowEarthAlignment() }),
    // Detect on a half-size copy of each frame.  Keypoint detection is the most memory
    // hungry step and its cost is per pixel, so this cuts it by about 4x, at some cost in
    // alignment quality.  Keypoint files are kept separately per setting, so switching
    // back and forth does not mix the two.
    // Replaced the "Half resolution keypoints" switch. DoubleField has no min/max, unlike
    // IntField, so a value under 1 is reachable from here; StarCore clamps anything <= 1 to
    // full resolution rather than honouring it, so that is harmless but not meaningful.
    DoubleField("Keypoint detection divisor", { it.alignmentKeypointDetectionDivisor }, { b, v -> b.setAlignmentKeypointDetectionDivisor(v) }, { it.hasAlignmentKeypointDetectionDivisor() }),
    BoolField("Write debug images", { it.alignmentWriteDebugImages }, { b, v -> b.setAlignmentWriteDebugImages(v) }, { it.hasAlignmentWriteDebugImages() }),
)

internal val HORIZON_FIELDS: List<ExpertField> = listOf(
    IntField("Strip width", { it.horizonStripWidth }, { b, v -> b.setHorizonStripWidth(v) }, 1, 8000, { it.hasHorizonStripWidth() }),
    BoolField("Canny edge detection", { it.useCannyForHorizonDetection }, { b, v -> b.setUseCannyForHorizonDetection(v) }, { it.hasUseCannyForHorizonDetection() }),
    DoubleField("Canny min threshold", { it.cannyMinThreshold }, { b, v -> b.setCannyMinThreshold(v) }, { it.hasCannyMinThreshold() }),
    DoubleField("Canny max threshold", { it.cannyMaxThreshold }, { b, v -> b.setCannyMaxThreshold(v) }, { it.hasCannyMaxThreshold() }),
    BoolField("Canny L2 gradient", { it.cannyUseL2Gradient }, { b, v -> b.setCannyUseL2Gradient(v) }, { it.hasCannyUseL2Gradient() }),
    IntField("Horizon shift", { it.horizonVerticalShiftAmount }, { b, v -> b.setHorizonVerticalShiftAmount(v) }, 0, 300, { it.hasHorizonVerticalShiftAmount() }),
    BoolField("Reference horizon smoothing", { it.useReferenceHorizonSmoothing }, { b, v -> b.setUseReferenceHorizonSmoothing(v) }, { it.hasUseReferenceHorizonSmoothing() }),
    IntField("Smoothing max distance", { it.referenceHorizonSmoothingMaxDistance }, { b, v -> b.setReferenceHorizonSmoothingMaxDistance(v) }, 1, 10000, { it.hasReferenceHorizonSmoothingMaxDistance() }),
    BoolField("Brightness refinement", { it.useReferenceHorizonBrightnessRefinement }, { b, v -> b.setUseReferenceHorizonBrightnessRefinement(v) }, { it.hasUseReferenceHorizonBrightnessRefinement() }),
    IntField("Refinement search radius", { it.referenceHorizonBrightnessRefinementSearchRadius }, { b, v -> b.setReferenceHorizonBrightnessRefinementSearchRadius(v) }, 1, 10000, { it.hasReferenceHorizonBrightnessRefinementSearchRadius() }),
    IntField("Refinement hist buckets", { it.referenceHorizonBrightnessRefinementHistBuckets }, { b, v -> b.setReferenceHorizonBrightnessRefinementHistBuckets(v) }, 2, 65536, { it.hasReferenceHorizonBrightnessRefinementHistBuckets() }),
    IntField("Neighborhood size", { it.referenceHorizonNeighborhoodSize }, { b, v -> b.setReferenceHorizonNeighborhoodSize(v) }, 1, 99, { it.hasReferenceHorizonNeighborhoodSize() }),
    BoolField("Spike removal", { it.horizonSpikeRemovalEnabled }, { b, v -> b.setHorizonSpikeRemovalEnabled(v) }, { it.hasHorizonSpikeRemovalEnabled() }),
    IntField("Spike max width", { it.horizonSpikeMaxWidth }, { b, v -> b.setHorizonSpikeMaxWidth(v) }, 1, 500, { it.hasHorizonSpikeMaxWidth() }),
    DoubleField("Spike max deviation", { it.horizonSpikeMaxDeviationFraction }, { b, v -> b.setHorizonSpikeMaxDeviationFraction(v) }, { it.hasHorizonSpikeMaxDeviationFraction() }),
    IntField("Spike window half", { it.horizonSpikeWindowHalf }, { b, v -> b.setHorizonSpikeWindowHalf(v) }, 10, 2000, { it.hasHorizonSpikeWindowHalf() }),
)

// NOTE: labels are the keys of the edit maps, so they have to stay unique across all
// three groups. "Max keypoint ops" here vs "Max keypoints" under Alignment are different
// settings and must keep different labels.
//
// The three fields with a min of 0 mean something specific at 0 rather than "off":
// no floor, no explicit cap, and never stream. 0 has to be reachable, and the daemon
// honours a present 0 rather than substituting its default.
internal val MEMORY_FIELDS: List<ExpertField> = listOf(
    IntField("Keypoint mem ×", { it.keypointMemoryMultiplier }, { b, v -> b.setKeypointMemoryMultiplier(v) }, 1, 200, { it.hasKeypointMemoryMultiplier() }),
    IntField("Outlier mem ×", { it.outlierMemoryMultiplier }, { b, v -> b.setOutlierMemoryMultiplier(v) }, 1, 50, { it.hasOutlierMemoryMultiplier() }),
    IntField("Merge mem ×", { it.mergeMemoryMultiplier }, { b, v -> b.setMergeMemoryMultiplier(v) }, 1, 50, { it.hasMergeMemoryMultiplier() }),
    IntField("Horizon mem ×", { it.horizonMemoryMultiplier }, { b, v -> b.setHorizonMemoryMultiplier(v) }, 1, 50, { it.hasHorizonMemoryMultiplier() }),
    // Horizon detection costs about the same whatever the frame size, so the multiplier
    // above under-reserves on small frames.  This floor is what covers them; it stops
    // mattering around 17MP.  0 = no floor.
    IntField("Horizon floor MB", { it.horizonReservationFloorMb }, { b, v -> b.setHorizonReservationFloorMb(v) }, 0, 16384, { it.hasHorizonReservationFloorMb() }),
    // 0 = no explicit cap; the memory budget decides.
    IntField("Max keypoint ops", { it.maxConcurrentKeypointOps }, { b, v -> b.setMaxConcurrentKeypointOps(v) }, 0, 256, { it.hasMaxConcurrentKeypointOps() }),
    // 0 = never stream, keep every source frame resident.
    IntField("Merge streaming MB", { it.mergeStreamingThresholdMb }, { b, v -> b.setMergeStreamingThresholdMb(v) }, 0, 65536, { it.hasMergeStreamingThresholdMb() }),
)

@Composable
private fun ExpertGroup(
    title: String,
    fields: List<ExpertField>,
    cfg: Config,
    boolEdits: SnapshotStateMap<String, Boolean>,
    textEdits: SnapshotStateMap<String, String>,
    daemonVersion: String?,
) {
    SettingGroup(title) {
        fields.forEach { f ->
            if (!f.has(cfg)) {
                // Shown rather than hidden, so it is clear the setting exists and what is
                // missing. Deliberately not editable: there is nothing on the other end to
                // apply it.
                UnsupportedRow(f.label, daemonVersion)
                return@forEach
            }
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
private fun UnsupportedRow(label: String, daemonVersion: String?) {
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(label, color = StarColors.textDisabled, fontSize = 12.sp, modifier = Modifier.weight(1f))
        Text(
            if (daemonVersion == null) "needs a newer engine" else "needs an engine newer than $daemonVersion",
            color = StarColors.textDisabled, fontSize = 10.sp,
        )
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
