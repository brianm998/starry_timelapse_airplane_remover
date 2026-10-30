package com.star.desktop.ui.dialogs

import androidx.compose.ui.platform.testTag
import androidx.compose.foundation.background
import androidx.compose.foundation.border
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
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshots.SnapshotStateMap
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.star.desktop.domain.FieldInput
import com.star.desktop.domain.SettingsChange
import com.star.desktop.domain.SettingsEdit
import com.star.desktop.engine.EngineStatus
import com.star.desktop.i18n.localized
import com.star.desktop.ui.app.AppScreen
import com.star.desktop.ui.app.AppViewModel
import com.star.desktop.ui.components.GlyphButton
import com.star.desktop.ui.components.HoverTip
import com.star.desktop.ui.theme.StarColors
import com.star.desktop.ui.theme.StarShapes
import com.star.proto.CleanMethod
import com.star.proto.Config
import com.star.proto.DetectionType
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch

/**
 * Processing settings sheet (macOS `ProcessingSettingsView`): the clean method and how strictly outliers are found, the scene and camera, how much
 * of this Mac to use, and, behind "Show Expert Settings", every tuning setting the engine has.
 *
 * Rows that do not apply to what is chosen are greyed (a sky-only sequence has no horizon to tune; a sub-setting means nothing while the setting
 * above it is off). A number outside its range is marked and Save waits until it is put right. Only what was changed is sent: Save resending every
 * setting would mark each one as chosen by the user, including ones the engine picks for itself (the keypoint divisor). Clicking outside the sheet
 * does nothing, so a stray click cannot throw the edits away, and a save that fails says why and leaves the sheet up.
 */
@Composable
fun ProcessingSettingsDialog(app: AppViewModel) {
    val scope = rememberCoroutineScope()
    val loaded by produceState<Config?>(null) { value = runCatching { app.sessions.getConfig() }.getOrNull() }
    // What the daemon says applying the edits would do to the work on disk; written by the effect below as the edits settle.
    var change by remember { mutableStateOf(SettingsChange.NONE) }
    val screen by app.screen.collectAsState()
    val svm = (screen as? AppScreen.Sequence)?.vm
    val processing by (svm?.isProcessing ?: remember { MutableStateFlow(false) }).collectAsState()
    val frameCount = svm?.frameCount ?: 1

    Box(Modifier.fillMaxSize().background(StarColors.scrim).clickable(enabled = false) {}, contentAlignment = Alignment.Center) {
        Column(
            modifier = Modifier
                .widthIn(max = 560.dp)
                .clip(StarShapes.card)
                .background(StarColors.prefsCard)
                .verticalScroll(rememberScrollState())
                .padding(24.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            Text(localized("ui.processing_settings"), color = StarColors.textPrimary, fontWeight = FontWeight.SemiBold, fontSize = 18.sp)

            // Under the title, and only over a sequence that has work on disk this change contradicts: a sequence nothing has been done to is
            // what this sheet was built for, and there is nothing to warn about there.
            if (change.contradictsFinishedWork) {
                HoverTip(localized("ui.already_processed_frames_have_different_settings_help")) {
                    Text(localized("ui.already_processed_frames_have_different_settings"), color = StarColors.red, fontSize = 14.sp)
                }
            }

            val cfg = loaded
            if (cfg == null) {
                Text(localized("ui.loading"), color = StarColors.textSecondary, fontSize = 13.sp)
                return@Column
            }

            // Which rows have their explanation open, by row id; the two buttons open and close all of them, the ones in folded groups too.
            val info = remember { androidx.compose.runtime.mutableStateMapOf<String, Boolean>() }
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.End)) {
                OutlinedButton(onClick = { info.clear() }) { Text(localized("ui.hide_info"), fontSize = 12.sp) }
                Button(
                    onClick = { ALL_INFO_IDS.forEach { info[it] = true } },
                    colors = ButtonDefaults.buttonColors(containerColor = StarColors.accent),
                ) { Text(localized("ui.show_info"), fontSize = 12.sp) }
            }

            var clean by remember(cfg) { mutableStateOf(cfg.cleanMethod) }
            var detection by remember(cfg) { mutableStateOf(cfg.detectionType) }
            var horizon by remember(cfg) { mutableStateOf(cfg.horizonDetectionEnabled) }
            var tripod by remember(cfg) { mutableStateOf(cfg.tripodHeadWasMoving) }
            var concurrency by remember(cfg) { mutableStateOf(cfg.numberOfFramesToProcessConcurrently.coerceAtLeast(1)) }
            // Daemons that predate the profile send none: they behave as Full.
            var useProfile by remember(cfg) { mutableStateOf(if (cfg.hasResourceProfile()) cfg.resourceProfile else "full") }
            val showExpert by app.showExpertSettings.collectAsState()
            // Expert-field edits: bools and raw text (parsed on save) keyed by field label.
            val boolEdits = remember(cfg) { androidx.compose.runtime.mutableStateMapOf<String, Boolean>() }
            val textEdits = remember(cfg) { androidx.compose.runtime.mutableStateMapOf<String, String>() }

            // Only the daemon's own machine's hardware is known here; a client's own machine may differ, so this reflects what the *daemon* can
            // actually do. Absent (older daemon) means "unknown," not "unsupported" -- do not disable.
            val gpuUnavailable = cfg.hasGpuHardwareAvailable() && !cfg.gpuHardwareAvailable
            val edit = SettingsEdit(horizon, tripod, clean, gpuUnavailable) { id -> boolEdits[id] ?: BOOL_FIELDS[id]?.get(cfg) ?: false }

            SettingGroup(
                localized("ui.clean_method"), info = info, infoId = "clean",
                help = choicesHelp(
                    localized("ui.automatic") to localized("ui.mode_desc_automatic"),
                    localized("ui.auto_selective") to localized("ui.mode_desc_auto_selective"),
                    localized("ui.selective") to localized("ui.mode_desc_selective"),
                ),
            ) {
                Segmented(
                    options = listOf(
                        CleanMethod.CLEAN_AUTOMATIC to localized("ui.automatic"),
                        CleanMethod.CLEAN_AUTOMATIC_TRUE to localized("ui.auto_selective"),
                        CleanMethod.CLEAN_SELECTIVE to localized("ui.selective"),
                    ),
                    selected = clean,
                    onSelect = { clean = it },
                )
                Text(
                    localized("ui.selective_auto_selective_detect_outlier"),
                    color = StarColors.textDisabled, fontSize = 10.sp,
                )
            }

            // How strictly outliers are looked for: only means something when the method finds outlier groups at all.
            SettingGroup(
                localized("ui.selective_processing_mode").removeSuffix(":"), enabled = edit.usesOutliers,
                info = info, infoId = "detection", help = localized("setting_help.selective_processing_mode"),
            ) {
                Segmented(
                    options = listOf(
                        DetectionType.DETECTION_MILD to localized("detection_type.mild"),
                        DetectionType.DETECTION_STRONG to localized("detection_type.strong"),
                        DetectionType.DETECTION_STRONGER to localized("detection_type.stronger"),
                        DetectionType.DETECTION_EXCESSIVE to localized("detection_type.excessive"),
                        // A config that has its own blob processor shows as this, rather than as none of the above.
                        DetectionType.DETECTION_CUSTOM to localized("detection_type.custom"),
                    ),
                    selected = detection,
                    onSelect = { detection = it },
                    enabled = edit.usesOutliers,
                )
            }

            SettingGroup(
                localized("ui.scene_type").removeSuffix(":"), info = info, infoId = "scene",
                help = choicesHelp(
                    localized("scene_type.sky_horizon") to localized("ui.sky_horizon_desc"),
                    localized("scene_type.sky_only") to localized("ui.sky_only_desc"),
                ),
            ) {
                Segmented(
                    options = listOf(true to localized("scene_type.sky_horizon"), false to localized("scene_type.sky_only")),
                    selected = horizon,
                    onSelect = { horizon = it },
                    tip = { localized(if (it) "ui.sky_horizon_help" else "ui.sky_only_help") },
                )
            }
            SettingGroup(
                localized("ui.camera_motion").removeSuffix(":"), info = info, infoId = "camera",
                help = choicesHelp(
                    localized("camera_motion.fixed") to localized("ui.camera_fixed_desc"),
                    localized("camera_motion.moving") to localized("ui.camera_moving_desc"),
                ),
            ) {
                Segmented(
                    options = listOf(false to localized("camera_motion.fixed"), true to localized("camera_motion.moving")),
                    selected = tripod,
                    onSelect = { tripod = it },
                    tip = { localized(if (it) "ui.camera_moving_help" else "ui.camera_fixed_help") },
                )
            }

            SettingGroup(localized("ui.use_of_this_mac")) {
                Segmented(
                    options = listOf(
                        "full" to localized("ui.use_full"),
                        "balanced" to localized("ui.use_balanced"),
                        "light" to localized("ui.use_light"),
                        "custom" to localized("ui.use_custom"),
                    ),
                    selected = useProfile,
                    onSelect = { useProfile = it },
                )
                Text(
                    localized("ui.use_of_this_mac_help"),
                    color = StarColors.textDisabled, fontSize = 10.sp,
                )
            }

            // The old "frames at once" number is Custom's pipeline depth cap: the other
            // profiles size the queue from the machine, so it is only shown for Custom.
            if (useProfile == "custom") {
                SettingGroup(localized("ui.use_custom_pipeline_depth")) {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        GlyphButton("−", localized("ui.fewer"), { concurrency = (concurrency - 1).coerceAtLeast(1) }, size = 24, fontSize = 14)
                        Text("$concurrency", color = StarColors.textPrimary, fontSize = 14.sp)
                        GlyphButton("+", localized("ui.more"), { concurrency += 1 }, size = 24, fontSize = 14)
                    }
                }
            }

            // Not an expert setting: GPU acceleration is one most people care about, so it is here without "Show Expert Settings" and open.
            GpuGroup(cfg, edit, boolEdits, info, app.engineStatus.value.let { (it as? EngineStatus.Connected)?.daemonVersion })

            // Nor is this: the cloud-aware merge, which anyone shooting a moving sky may want.
            ExpertGroup(localized("ui.merge_settings"), MERGE_FIELDS, cfg, edit, boolEdits, textEdits, info, frameCount, app.engineStatus.value.let { (it as? EngineStatus.Connected)?.daemonVersion })

            ToggleRow(localized(if (showExpert) "ui.hide_expert_settings" else "ui.show_expert_settings"), showExpert) { app.setShowExpertSettings(it) }
            if (showExpert) {
                // Only to word the "needs a newer engine" note; whether a field is supported
                // is decided by its presence in the config the daemon sent, not by this.
                val daemonVersion = (app.engineStatus.value as? EngineStatus.Connected)?.daemonVersion
                ExpertGroup(localized("ui.alignment_settings"), ALIGNMENT_FIELDS, cfg, edit, boolEdits, textEdits, info, frameCount, daemonVersion)
                ExpertGroup(localized("ui.horizon_settings"), HORIZON_FIELDS, cfg, edit, boolEdits, textEdits, info, frameCount, daemonVersion)
                ExpertGroup(localized("ui.memory_settings"), MEMORY_FIELDS, cfg, edit, boolEdits, textEdits, info, frameCount, daemonVersion)
            }

            val frameMax = frameCount
            // The expert fields this sheet is going to send: the ones that apply, with a value that differs from what the daemon has.
            val problems = ALL_FIELDS.filter { f ->
                f.has(cfg) && f.enabled(edit) && f is NumberField && textEdits[f.label]?.let { !f.isValid(it, frameMax) } == true
            }.map { it.label }.toSet()

            // The config the edits make: what Save applies, and what the daemon is asked about to say whether it contradicts finished work.
            // Only the changes are in it: resending every setting would mark each as chosen by the user, including the ones the engine picks
            // for itself.
            val proposed: Config = run {
                val b = Config.newBuilder()
                    .setCleanMethod(clean)
                    .setDetectionType(detection)
                    .setHorizonDetectionEnabled(horizon)
                    .setTripodHeadWasMoving(tripod)
                    .setNumberOfFramesToProcessConcurrently(concurrency)
                if (cfg.hasResourceProfile() && cfg.resourceProfile != useProfile || !cfg.hasResourceProfile() && useProfile != "full") {
                    b.setResourceProfile(useProfile)
                }
                // Unsupported fields are skipped: they render as read-only so there should be no edit to apply, and sending one to a daemon that
                // does not know the field would be a silent no-op at best. A field that does not apply, or whose text is not a valid number,
                // is not sent either.
                ALL_FIELDS.filter { it.has(cfg) && it.enabled(edit) }.forEach { f ->
                    when (f) {
                        is BoolField -> boolEdits[f.label]?.takeIf { it != f.get(cfg) }?.let { f.set(b, it) }
                        is IntField -> textEdits[f.label]?.let { FieldInput.int(it, f.min, f.maxFor(frameMax)) }?.takeIf { it != f.get(cfg) }?.let { f.set(b, it) }
                        is DoubleField -> textEdits[f.label]?.let { FieldInput.double(it, f.min, f.max) }?.takeIf { it != f.get(cfg) }?.let { f.set(b, it) }
                    }
                }
                b.build()
            }

            // Asked of the daemon after each edit, once they stop (a number being typed is a burst of them): does this contradict frames already
            // processed? Then the sheet says so, and the button that goes on is Update.
            LaunchedEffect(proposed) {
                delay(300)
                change = SettingsChange.of(app.previewConfigChange(proposed))
            }
            var askUpdate by remember { mutableStateOf(false) }

            // Save the settings and close; with [goOn] go on, which is to start processing (macOS "Process Now") or, over a run that is going and
            // has nothing here to change in, to put its status back up (the button is Show Progress then). A save the daemon refuses is said, and
            // the sheet stays up with the edits in it.
            val showsProgress = change.showsProgress(processing)
            val save: (Boolean) -> Unit = { goOn ->
                scope.launch {
                    val saved = runCatching { app.updateSessionConfig(proposed) }
                    saved.onFailure { app.report(it.message ?: it.toString()) }
                    if (saved.isSuccess) {
                        app.closeSettings()
                        if (goOn) {
                            if (showsProgress) svm?.reopenProcessingModal() else app.requestProcessAll()
                        }
                    }
                }
            }
            Row(Modifier.fillMaxWidth().padding(top = 8.dp), horizontalArrangement = Arrangement.spacedBy(10.dp, Alignment.End)) {
                OutlinedButton(onClick = app::closeSettings) { Text(localized("ui.cancel")) }
                OutlinedButton(onClick = { save(false) }, enabled = problems.isEmpty()) { Text(localized("ui.save")) }
                Button(
                    // Update, over frames this change contradicts, asks before it acts: it does not start a run over an untouched sequence, it
                    // changes one that is part done.
                    onClick = { if (change.contradictsFinishedWork) askUpdate = true else save(true) },
                    enabled = problems.isEmpty(),
                    colors = ButtonDefaults.buttonColors(containerColor = StarColors.accent),
                    modifier = Modifier.testTag("settings.process"),
                ) { Text(localized(change.buttonKey(processing))) }
            }
            if (askUpdate) {
                // The whole question as the title. No is first and Esc, and does the safe thing: nothing is deleted, and the new settings
                // apply only to the frames still to do. Yes, which Return takes, throws away what the change invalidated and builds it again.
                PromptCard(
                    onScrimClick = null,
                    onDefaultAction = { askUpdate = false; app.updateSettingsAndProcess(proposed, reprocess = true) },
                    onEscape = { askUpdate = false; app.updateSettingsAndProcess(proposed, reprocess = false) },
                ) {
                    Text(localized("ui.reprocess_already_processed_frames_question"), color = StarColors.textPrimary, fontWeight = FontWeight.SemiBold, fontSize = 16.sp)
                    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(10.dp, Alignment.End)) {
                        OutlinedButton(onClick = { askUpdate = false; app.updateSettingsAndProcess(proposed, reprocess = false) }) { Text(localized("ui.no")) }
                        Button(
                            onClick = { askUpdate = false; app.updateSettingsAndProcess(proposed, reprocess = true) },
                            colors = ButtonDefaults.buttonColors(containerColor = StarColors.accent),
                        ) { Text(localized("ui.yes")) }
                    }
                }
            }
        }
    }
}

@Composable
private fun SettingGroup(
    title: String,
    enabled: Boolean = true,
    info: SnapshotStateMap<String, Boolean>? = null,
    infoId: String? = null,
    help: String? = null,
    content: @Composable () -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        if (info != null && infoId != null && help != null) {
            InfoRow(infoId, info, help) { Text(title, color = if (enabled) StarColors.textSecondary else StarColors.textDisabled, fontSize = 12.sp) }
        } else {
            Text(title, color = if (enabled) StarColors.textSecondary else StarColors.textDisabled, fontSize = 12.sp)
        }
        content()
    }
}

/** What each of a picker's choices means, under its title: a heading and a paragraph apiece (macOS's info panel for these rows). */
private fun choicesHelp(vararg choices: Pair<String, String>): String = choices.joinToString("\n\n") { (name, meaning) -> "$name\n$meaning" }

@Composable
private fun <T> Segmented(
    options: List<Pair<T, String>>,
    selected: T,
    onSelect: (T) -> Unit,
    enabled: Boolean = true,
    /** What hovering an option says it means (macOS's `.help` on each choice). */
    tip: (T) -> String? = { null },
) {
    Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
        options.forEach { (value, label) ->
            val isSel = value == selected
            val option: @Composable () -> Unit = {
                Box(
                    Modifier
                        .clip(RoundedCornerShape(5.dp))
                        .background(if (isSel) (if (enabled) StarColors.accent else StarColors.gray) else StarColors.cellDefault)
                        .clickable(enabled = enabled) { onSelect(value) }
                        .padding(horizontal = 10.dp, vertical = 5.dp),
                ) { Text(label, color = if (isSel) Color.White else if (enabled) StarColors.textPrimary else StarColors.textDisabled, fontSize = 11.sp) }
            }
            val text = tip(value)
            if (text == null) option() else HoverTip(text, option)
        }
    }
}

/** The (i) beside a row: green to open the explanation of it, red to close it (macOS). */
@Composable
private fun InfoButton(open: Boolean, onClick: () -> Unit) {
    HoverTip(localized(if (open) "ui.hide_information" else "ui.show_information")) {
        Text(
            "ⓘ", color = if (open) StarColors.red else StarColors.green, fontSize = 16.sp,
            modifier = Modifier.clip(RoundedCornerShape(10.dp)).clickable(onClick = onClick).padding(horizontal = 4.dp),
        )
    }
}

/**
 * A row with its explanation: [content] and an (i) that opens [help] under it. [open] holds which rows are showing theirs, by [id], so the
 * sheet's Show Info and Hide Info can open and close every one at once, the ones in folded groups too.
 */
@Composable
private fun InfoRow(id: String, open: SnapshotStateMap<String, Boolean>, help: String?, content: @Composable () -> Unit) {
    Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.weight(1f)) { content() }
            if (help != null) InfoButton(open[id] == true) { open[id] = open[id] != true }
        }
        if (help != null && open[id] == true) {
            Text(help, color = StarColors.textSecondary, fontSize = 11.sp, modifier = Modifier.padding(start = 4.dp, bottom = 4.dp))
        }
    }
}

@Composable
private fun ToggleRow(label: String, value: Boolean, enabled: Boolean = true, onChange: (Boolean) -> Unit) {
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.SpaceBetween) {
        Text(label, color = if (enabled) StarColors.textPrimary else StarColors.textDisabled, fontSize = 13.sp)
        Switch(checked = value, onCheckedChange = onChange, enabled = enabled)
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
///
/// `label` is the field's stable id (the key of the edit maps, and what the tests name it by);
/// what the row says is `labelKey`'s text in the user's language. `enabled` says whether the
/// row applies to what is being edited (see [SettingsEdit]); a row that does not is greyed and
/// its edit, if any, is not sent.
internal sealed interface ExpertField {
    val label: String
    val labelKey: String
    val has: (Config) -> Boolean
    val enabled: (SettingsEdit) -> Boolean

    /** The catalogue entries that explain this setting (macOS's per-row info text), shown a paragraph each; none for a setting with nothing to say. */
    val helpKeys: List<String> get() = FIELD_HELP[label].orEmpty()
}

/** What explains each field: the long-form text macOS shows under a row's (i), for those that have one, and what its two choices mean for a yes/no setting. */
internal val FIELD_HELP: Map<String, List<String>> = mapOf(
    "Neighbor frames" to listOf("setting_help.neighbor_frames"),
    "Static neighbor frames" to listOf("setting_help.static_neighbor_frames"),
    "Pixel threshold" to listOf("setting_help.pixel_threshold"),
    "Max keypoints" to listOf("setting_help.max_keypoints"),
    "Ground horizon extension" to listOf("setting_help.ground_horizon_extension"),
    "Sky horizon extension" to listOf("setting_help.sky_horizon_extension"),
    "Base image dilate size" to listOf("setting_help.base_image_dilation_size"),
    "Base image threshold" to listOf("setting_help.base_image_threshold"),
    "Homography smoothing ε" to listOf("setting_help.homography_smoothing"),
    "Allow earth alignment" to listOf("setting_help.allow_earth_alignment"),
    "Keypoint detection divisor" to listOf("setting_help.keypoint_divisor"),
    "Write debug images" to listOf("setting_help.write_debug_images"),
    "Canny edge detection" to listOf("ui.canny_yes_desc", "ui.canny_no_desc"),
    "Canny min threshold" to listOf("setting_help.canny_min_threshold"),
    "Canny max threshold" to listOf("setting_help.canny_max_threshold"),
    "Canny L2 gradient" to listOf("ui.l1_norm_help", "ui.l2_norm_help"),
    "Reference horizon smoothing" to listOf("setting_help.reference_smoothing"),
    "Smoothing max distance" to listOf("setting_help.reference_smoothing_distance"),
    "Brightness refinement" to listOf("setting_help.brightness_refinement"),
    "Refinement search radius" to listOf("setting_help.brightness_refinement_search_radius"),
    "Refinement hist buckets" to listOf("setting_help.brightness_refinement_buckets"),
    "Neighborhood size" to listOf("setting_help.neighbourhood_size"),
    "Spike removal" to listOf("setting_help.spike_removal"),
    "Spike max width" to listOf("setting_help.spike_max_width"),
    "Spike max deviation" to listOf("setting_help.spike_max_deviation"),
    "Spike window half" to listOf("setting_help.spike_window_half"),
    "Keypoint mem ×" to listOf("setting_help.keypoint_mem"),
    "Outlier mem ×" to listOf("setting_help.outlier_mem"),
    "Merge mem ×" to listOf("setting_help.merge_mem"),
    "Horizon mem ×" to listOf("setting_help.horizon_mem"),
    "Horizon floor MB" to listOf("setting_help.horizon_floor"),
    "Max keypoint ops" to listOf("setting_help.max_keypoint_ops"),
    "Merge streaming MB" to listOf("setting_help.merge_streaming_mb"),
    "Memory budget" to listOf("setting_help.memory_budget"),
    "Cloud-aware merge" to listOf("setting_help.cloud_aware_merge"),
    "Use GPU for Align & Merge" to listOf("setting_help.gpu_merge"),
    "Use GPU for SIFT" to listOf("setting_help.gpu_sift"),
    "Use GPU for AKAZE" to listOf("setting_help.gpu_akaze"),
)

/** The text under a field's (i): each of its entries in the user's language, a paragraph apiece. */
internal fun ExpertField.helpText(): String? = helpKeys.takeIf { it.isNotEmpty() }?.joinToString("\n\n") { localized(it) }

/** A field that takes a number, which has a range it must stay in. */
internal sealed interface NumberField : ExpertField {
    /** Whether [text] is a number this field accepts when the open sequence has [frameCount] frames. */
    fun isValid(text: String, frameCount: Int): Boolean
}

private val ALWAYS: (SettingsEdit) -> Boolean = { true }

internal class IntField(
    override val label: String,
    override val labelKey: String,
    val get: (Config) -> Int,
    val set: (Config.Builder, Int) -> Config.Builder,
    val min: Int,
    val max: Int,
    override val has: (Config) -> Boolean,
    override val enabled: (SettingsEdit) -> Boolean = ALWAYS,
    /** The largest value for a sequence of this many frames, for the settings that count neighbors (never more than the others there are). */
    val maxForFrames: ((Int) -> Int)? = null,
) : NumberField {
    fun maxFor(frameCount: Int): Int = maxForFrames?.invoke(frameCount)?.coerceIn(min, max) ?: max
    override fun isValid(text: String, frameCount: Int) = FieldInput.int(text, min, maxFor(frameCount)) != null
}

internal class DoubleField(
    override val label: String,
    override val labelKey: String,
    val get: (Config) -> Double,
    val set: (Config.Builder, Double) -> Config.Builder,
    override val has: (Config) -> Boolean,
    /** Inclusive bounds on what the field accepts; a value outside them is not applied. Unbounded unless the setting has a range that means something. */
    val min: Double = Double.NEGATIVE_INFINITY,
    val max: Double = Double.POSITIVE_INFINITY,
    override val enabled: (SettingsEdit) -> Boolean = ALWAYS,
) : NumberField {
    override fun isValid(text: String, frameCount: Int) = FieldInput.double(text, min, max) != null
}

internal class BoolField(
    override val label: String,
    override val labelKey: String,
    val get: (Config) -> Boolean,
    val set: (Config.Builder, Boolean) -> Config.Builder,
    override val has: (Config) -> Boolean,
    override val enabled: (SettingsEdit) -> Boolean = ALWAYS,
) : ExpertField

// The ids the rules refer to.
private const val CANNY = "Canny edge detection"
private const val SMOOTHING = "Reference horizon smoothing"
private const val BRIGHTNESS = "Brightness refinement"
private const val SPIKES = "Spike removal"

/** The horizon rows: moot for a sky-only sequence. */
private val NEEDS_HORIZON: (SettingsEdit) -> Boolean = { !it.skyOnly }

/** The reference-horizon rows: they smooth between horizons the user painted, which only a camera that moved has. */
private val NEEDS_MOVING_HORIZON: (SettingsEdit) -> Boolean = { !it.skyOnly && !it.cameraFixed }

internal val ALIGNMENT_FIELDS: List<ExpertField> = listOf(
    IntField("Neighbor frames", "ui.neighbor_frame_count", { it.numberAlignedNeighborFrames }, { b, v -> b.setNumberAlignedNeighborFrames(v) }, 1, 1000, { it.hasNumberAlignedNeighborFrames() },
        maxForFrames = { it - 1 }),
    // Only a camera that did not move has frames whose horizons can be merged; a moving camera uses the aligned neighbors above.
    IntField("Static neighbor frames", "ui.static_neighbor_frame_count", { it.numberStaticNeighborFrames }, { b, v -> b.setNumberStaticNeighborFrames(v) }, 1, 1000, { it.hasNumberStaticNeighborFrames() },
        enabled = { it.cameraFixed }, maxForFrames = { it - 1 }),
    // How far a pixel may be from its neighbours' before it is thrown out and replaced.  The macOS gui has had this row (and a right-panel slider) all along.
    DoubleField("Pixel threshold", "ui.pixel_threshold", { it.pixelThreshold }, { b, v -> b.setPixelThreshold(v) }, { it.hasPixelThreshold() },
        min = 0.001, max = 10.0),
    IntField("Max keypoints", "ui.max_keypoints", { it.alignmentMaxKeypoints }, { b, v -> b.setAlignmentMaxKeypoints(v) }, 4, 10000, { it.hasAlignmentMaxKeypoints() }),
    IntField("Ground horizon extension", "ui.ground_horizon_extension", { it.alignmentGroundHorizonExtension }, { b, v -> b.setAlignmentGroundHorizonExtension(v) }, 0, 10000, { it.hasAlignmentGroundHorizonExtension() }),
    IntField("Sky horizon extension", "ui.sky_horizon_extension", { it.alignmentSkyHorizonExtension }, { b, v -> b.setAlignmentSkyHorizonExtension(v) }, 0, 10000, { it.hasAlignmentSkyHorizonExtension() }),
    IntField("Base image dilate size", "ui.base_image_dilation_size", { it.alignmentBaseImageDilateSize }, { b, v -> b.setAlignmentBaseImageDilateSize(v) }, 4, 10000, { it.hasAlignmentBaseImageDilateSize() }),
    IntField("Base image threshold", "ui.base_image_threshold", { it.alignmentBaseImageThresholdValue }, { b, v -> b.setAlignmentBaseImageThresholdValue(v) }, 1, 255, { it.hasAlignmentBaseImageThresholdValue() }),
    DoubleField("Homography smoothing ε", "ui.homography_smoothing", { it.homographySmoothingEpsilon }, { b, v -> b.setHomographySmoothingEpsilon(v) }, { it.hasHomographySmoothingEpsilon() },
        min = 0.0, max = 10.0, enabled = NEEDS_HORIZON),
    BoolField("Allow earth alignment", "ui.allow_earth_alignment", { it.allowEarthAlignment }, { b, v -> b.setAllowEarthAlignment(v) }, { it.hasAllowEarthAlignment() }),
    // Detect on a smaller copy of each frame.  Keypoint detection is the most memory hungry step and its cost is per pixel, so this cuts it by
    // about the square of the divisor, at some cost in alignment quality.  Keypoint files are kept separately per setting, so switching back and
    // forth does not mix the two.  1 (full size) to 8, both inclusive; StarCore clamps anything <= 1 to full resolution.
    DoubleField("Keypoint detection divisor", "ui.keypoint_divisor", { it.alignmentKeypointDetectionDivisor }, { b, v -> b.setAlignmentKeypointDetectionDivisor(v) }, { it.hasAlignmentKeypointDetectionDivisor() },
        min = 1.0, max = 8.0),
    BoolField("Write debug images", "ui.write_debug_images", { it.alignmentWriteDebugImages }, { b, v -> b.setAlignmentWriteDebugImages(v) }, { it.hasAlignmentWriteDebugImages() }),
)

internal val HORIZON_FIELDS: List<ExpertField> = listOf(
    BoolField(CANNY, "ui.canny_edge_detection", { it.useCannyForHorizonDetection }, { b, v -> b.setUseCannyForHorizonDetection(v) }, { it.hasUseCannyForHorizonDetection() },
        enabled = NEEDS_HORIZON),
    DoubleField("Canny min threshold", "ui.canny_min_threshold", { it.cannyMinThreshold }, { b, v -> b.setCannyMinThreshold(v) }, { it.hasCannyMinThreshold() },
        min = 1.0, max = 300.0, enabled = { !it.skyOnly && it.isOn(CANNY) }),
    DoubleField("Canny max threshold", "ui.canny_max_threshold", { it.cannyMaxThreshold }, { b, v -> b.setCannyMaxThreshold(v) }, { it.hasCannyMaxThreshold() },
        min = 1.0, max = 300.0, enabled = { !it.skyOnly && it.isOn(CANNY) }),
    BoolField("Canny L2 gradient", "ui.canny_gradient_method", { it.cannyUseL2Gradient }, { b, v -> b.setCannyUseL2Gradient(v) }, { it.hasCannyUseL2Gradient() },
        enabled = { !it.skyOnly && it.isOn(CANNY) }),
    BoolField(SMOOTHING, "ui.reference_horizon_smoothing", { it.useReferenceHorizonSmoothing }, { b, v -> b.setUseReferenceHorizonSmoothing(v) }, { it.hasUseReferenceHorizonSmoothing() },
        enabled = NEEDS_MOVING_HORIZON),
    IntField("Smoothing max distance", "ui.reference_smoothing_distance", { it.referenceHorizonSmoothingMaxDistance }, { b, v -> b.setReferenceHorizonSmoothingMaxDistance(v) }, 1, 10000, { it.hasReferenceHorizonSmoothingMaxDistance() },
        enabled = { NEEDS_MOVING_HORIZON(it) && it.isOn(SMOOTHING) }),
    BoolField(BRIGHTNESS, "ui.reference_horizon_brightness_refinement", { it.useReferenceHorizonBrightnessRefinement }, { b, v -> b.setUseReferenceHorizonBrightnessRefinement(v) }, { it.hasUseReferenceHorizonBrightnessRefinement() },
        enabled = NEEDS_MOVING_HORIZON),
    IntField("Refinement search radius", "ui.brightness_refinement_search_radius", { it.referenceHorizonBrightnessRefinementSearchRadius }, { b, v -> b.setReferenceHorizonBrightnessRefinementSearchRadius(v) }, 1, 10000, { it.hasReferenceHorizonBrightnessRefinementSearchRadius() },
        enabled = { NEEDS_MOVING_HORIZON(it) && it.isOn(BRIGHTNESS) }),
    IntField("Refinement hist buckets", "ui.brightness_refinement_histogram_buckets", { it.referenceHorizonBrightnessRefinementHistBuckets }, { b, v -> b.setReferenceHorizonBrightnessRefinementHistBuckets(v) }, 2, 65536, { it.hasReferenceHorizonBrightnessRefinementHistBuckets() },
        enabled = { NEEDS_MOVING_HORIZON(it) && it.isOn(BRIGHTNESS) }),
    IntField("Neighborhood size", "ui.reference_horizon_neighbourhood_size", { it.referenceHorizonNeighborhoodSize }, { b, v -> b.setReferenceHorizonNeighborhoodSize(v) }, 1, 99, { it.hasReferenceHorizonNeighborhoodSize() },
        enabled = { NEEDS_MOVING_HORIZON(it) && it.isOn(BRIGHTNESS) }),
    BoolField(SPIKES, "ui.horizon_spike_removal", { it.horizonSpikeRemovalEnabled }, { b, v -> b.setHorizonSpikeRemovalEnabled(v) }, { it.hasHorizonSpikeRemovalEnabled() },
        enabled = { NEEDS_MOVING_HORIZON(it) && it.isOn(BRIGHTNESS) }),
    IntField("Spike max width", "ui.spike_max_width_columns", { it.horizonSpikeMaxWidth }, { b, v -> b.setHorizonSpikeMaxWidth(v) }, 1, 500, { it.hasHorizonSpikeMaxWidth() },
        enabled = { NEEDS_MOVING_HORIZON(it) && it.isOn(BRIGHTNESS) && it.isOn(SPIKES) }),
    DoubleField("Spike max deviation", "ui.spike_max_deviation_fraction", { it.horizonSpikeMaxDeviationFraction }, { b, v -> b.setHorizonSpikeMaxDeviationFraction(v) }, { it.hasHorizonSpikeMaxDeviationFraction() },
        min = 0.001, max = 0.5, enabled = { NEEDS_MOVING_HORIZON(it) && it.isOn(BRIGHTNESS) && it.isOn(SPIKES) }),
    IntField("Spike window half", "ui.spike_detection_window_half", { it.horizonSpikeWindowHalf }, { b, v -> b.setHorizonSpikeWindowHalf(v) }, 10, 2000, { it.hasHorizonSpikeWindowHalf() },
        enabled = { NEEDS_MOVING_HORIZON(it) && it.isOn(BRIGHTNESS) && it.isOn(SPIKES) }),
)

// NOTE: labels are the keys of the edit maps, so they have to stay unique across all
// three groups. "Max keypoint ops" here vs "Max keypoints" under Alignment are different
// settings and must keep different labels.
//
// The three fields with a min of 0 mean something specific at 0 rather than "off":
// no floor, no explicit cap, and never stream. 0 has to be reachable, and the daemon
// honours a present 0 rather than substituting its default.
internal val MEMORY_FIELDS: List<ExpertField> = listOf(
    IntField("Keypoint mem ×", "ui.keypoint_mem", { it.keypointMemoryMultiplier }, { b, v -> b.setKeypointMemoryMultiplier(v) }, 1, 200, { it.hasKeypointMemoryMultiplier() }),
    IntField("Outlier mem ×", "ui.outlier_mem", { it.outlierMemoryMultiplier }, { b, v -> b.setOutlierMemoryMultiplier(v) }, 1, 50, { it.hasOutlierMemoryMultiplier() }),
    IntField("Merge mem ×", "ui.merge_mem", { it.mergeMemoryMultiplier }, { b, v -> b.setMergeMemoryMultiplier(v) }, 1, 50, { it.hasMergeMemoryMultiplier() }),
    IntField("Horizon mem ×", "ui.horizon_mem", { it.horizonMemoryMultiplier }, { b, v -> b.setHorizonMemoryMultiplier(v) }, 1, 50, { it.hasHorizonMemoryMultiplier() }),
    // Horizon detection costs about the same whatever the frame size, so the multiplier
    // above under-reserves on small frames.  This floor is what covers them; it stops
    // mattering around 17MP.  0 = no floor.
    IntField("Horizon floor MB", "ui.horizon_floor_mb", { it.horizonReservationFloorMb }, { b, v -> b.setHorizonReservationFloorMb(v) }, 0, 16384, { it.hasHorizonReservationFloorMb() }),
    // 0 = no explicit cap; the memory budget decides.
    IntField("Max keypoint ops", "ui.max_keypoint_ops", { it.maxConcurrentKeypointOps }, { b, v -> b.setMaxConcurrentKeypointOps(v) }, 0, 256, { it.hasMaxConcurrentKeypointOps() }),
    // 0 = never stream, keep every source frame resident.
    IntField("Merge streaming MB", "ui.merge_streaming_mb", { it.mergeStreamingThresholdMb }, { b, v -> b.setMergeStreamingThresholdMb(v) }, 0, 65536, { it.hasMergeStreamingThresholdMb() }),
    // The fraction of this machine's memory star may reserve for work in flight: 0.1 to 0.95, inclusive (the daemon clamps to the same). The default
    // 0.85 leaves the rest of the machine about 15%. Applied as given only under the Custom use of this Mac.
    DoubleField("Memory budget", "ui.memory_budget", { it.maxMatMemoryFraction }, { b, v -> b.setMaxMatMemoryFraction(v) }, { it.hasMaxMatMemoryFraction() }, min = 0.1, max = 0.95),
)

// On by default in StarCore's own Config, so a daemon this dialog talks to always sends
// it. `gpu_hardware_available` is not an ExpertField at all -- it is read-only, computed
// fresh by the daemon from its own machine's hardware, and rendered separately below
// rather than through ExpertGroup's editable/unsupported-row machinery, which assumes
// every field is something the user can set.
// Labeled "for Align & Merge," not a plain "GPU acceleration," so it reads as one specific
// step rather than a master switch -- it wires to the wire-stable `useGpuAcceleration` proto
// field/StarCore `Config.useGPUForMerge` regardless; only the label users see changed.
internal const val GPU_FOR_MERGE_LABEL = "Use GPU for Align & Merge"
// Independent of GPU_FOR_MERGE_LABEL and of each other -- see StarCore
// Config.useGPUForSIFT / .useGPUForAKAZE. Both off by default.
internal const val GPU_FOR_SIFT_LABEL = "Use GPU for SIFT"
internal const val GPU_FOR_AKAZE_LABEL = "Use GPU for AKAZE"

internal val GPU_FIELD_LABELS = setOf(GPU_FOR_MERGE_LABEL, GPU_FOR_SIFT_LABEL, GPU_FOR_AKAZE_LABEL)

/** Greyed and forced off on a machine with no GPU star can use: a toggle that could be turned on there would be a lie. */
private val NEEDS_GPU: (SettingsEdit) -> Boolean = { !it.gpuUnavailable }

// Not an expert setting either: whether fast-moving clouds come out banded is something anyone shooting a moving sky wants to be able to turn on.
// Off unless asked for (StarCore Config.cloudAwareMerge); turning it on or off makes the daemon redo the star aligned merge of frames already processed,
// which the sheet's contradiction check already says through the preview of the proposed config.
internal val MERGE_FIELDS: List<ExpertField> = listOf(
    BoolField("Cloud-aware merge", "ui.cloud_aware_merge", { it.cloudAwareMerge }, { b, v -> b.setCloudAwareMerge(v) }, { it.hasCloudAwareMerge() }),
)

internal val PERFORMANCE_FIELDS: List<ExpertField> = listOf(
    BoolField(GPU_FOR_MERGE_LABEL, "ui.use_gpu_for_merge", { it.useGpuAcceleration }, { b, v -> b.setUseGpuAcceleration(v) }, { it.hasUseGpuAcceleration() }, enabled = NEEDS_GPU),
    BoolField(GPU_FOR_SIFT_LABEL, "ui.use_gpu_for_sift", { it.useGpuForSift }, { b, v -> b.setUseGpuForSift(v) }, { it.hasUseGpuForSift() }, enabled = NEEDS_GPU),
    BoolField(GPU_FOR_AKAZE_LABEL, "ui.use_gpu_for_akaze", { it.useGpuForAkaze }, { b, v -> b.setUseGpuForAkaze(v) }, { it.hasUseGpuForAkaze() }, enabled = NEEDS_GPU),
)

private val ALL_FIELDS: List<ExpertField> = ALIGNMENT_FIELDS + HORIZON_FIELDS + MEMORY_FIELDS + MERGE_FIELDS + PERFORMANCE_FIELDS

/** Every row that has an explanation, which Show Info opens: the pickers and each field with help text. */
private val ALL_INFO_IDS: List<String> = listOf("clean", "detection", "scene", "camera") + ALL_FIELDS.filter { it.helpKeys.isNotEmpty() }.map { it.label }

/** The toggles by id, for the rules that read one toggle from another's row. */
private val BOOL_FIELDS: Map<String, BoolField> = ALL_FIELDS.filterIsInstance<BoolField>().associateBy { it.label }

@Composable
private fun ExpertGroup(
    title: String,
    fields: List<ExpertField>,
    cfg: Config,
    edit: SettingsEdit,
    boolEdits: SnapshotStateMap<String, Boolean>,
    textEdits: SnapshotStateMap<String, String>,
    info: SnapshotStateMap<String, Boolean>,
    frameCount: Int,
    daemonVersion: String?,
) {
    SettingGroup(title) {
        fields.forEach { f ->
            val label = localized(f.labelKey).removeSuffix(":")
            if (!f.has(cfg)) {
                // Shown rather than hidden, so it is clear the setting exists and what is
                // missing. Deliberately not editable: there is nothing on the other end to
                // apply it.
                UnsupportedRow(label, daemonVersion)
                return@forEach
            }
            val enabled = f.enabled(edit)
            InfoRow(f.label, info, f.helpText()) {
                when (f) {
                    is BoolField -> ToggleRow(label, boolEdits[f.label] ?: f.get(cfg), enabled = enabled) { boolEdits[f.label] = it }
                    is IntField -> NumberRow(
                        label, textEdits[f.label] ?: f.get(cfg).toString(), enabled,
                        problem = if (f.isValid(textEdits[f.label] ?: f.get(cfg).toString(), frameCount)) null
                        else localized("ui.enter_a_whole_number_from_a_to_b", f.min, f.maxFor(frameCount)),
                    ) { textEdits[f.label] = FieldInput.wholeNumberChars(it) }
                    is DoubleField -> NumberRow(
                        label, textEdits[f.label] ?: f.get(cfg).toString(), enabled,
                        problem = if (f.isValid(textEdits[f.label] ?: f.get(cfg).toString(), frameCount)) null
                        else localized("ui.enter_a_number_from_a_to_b", FieldInput.bound(f.min), FieldInput.bound(f.max)),
                    ) { textEdits[f.label] = FieldInput.decimalChars(it) }
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
            if (daemonVersion == null) localized("ui.needs_a_newer_engine") else localized("ui.needs_an_engine_newer_than", daemonVersion),
            color = StarColors.textDisabled, fontSize = 10.sp,
        )
    }
}

/**
 * GPU Settings (macOS's section of the same name): three independent toggles, each for one step, and a line saying whether this machine has a GPU
 * star can use and which. Open to begin with, and it can be folded away. A toggle on a machine without one is greyed and shown off, which the status
 * line explains: without it a toggle that cannot be turned on would look broken rather than moot.
 */
@Composable
private fun GpuGroup(cfg: Config, edit: SettingsEdit, boolEdits: SnapshotStateMap<String, Boolean>, info: SnapshotStateMap<String, Boolean>, daemonVersion: String?) {
    var expanded by remember { mutableStateOf(true) }
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Row(Modifier.fillMaxWidth().clickable { expanded = !expanded }, verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            Text(if (expanded) "▼" else "▶", color = StarColors.textSecondary, fontSize = 10.sp)
            Text(localized("ui.gpu_settings"), color = StarColors.textSecondary, fontSize = 12.sp)
        }
        // Each toggle controls one processing step only: "GPU Settings" must not read as one switch for the whole pipeline.
        Text(localized("ui.gpu_settings_scope_note"), color = StarColors.textDisabled, fontSize = 10.sp)
        // Said whether or not the section is open. Absent (an older daemon) means unknown, not unsupported.
        if (cfg.hasGpuHardwareAvailable()) GPUHardwareStatusRow(cfg.gpuHardwareAvailable, if (cfg.hasGpuDeviceName()) cfg.gpuDeviceName else null)
        if (expanded) {
            PERFORMANCE_FIELDS.forEach { f ->
                if (!f.has(cfg)) { UnsupportedRow(localized(f.labelKey).removeSuffix(":"), daemonVersion); return@forEach }
                if (f is BoolField) {
                    InfoRow(f.label, info, f.helpText()) {
                        ToggleRow(
                            localized(f.labelKey).removeSuffix(":"),
                            if (!f.enabled(edit)) false else (boolEdits[f.label] ?: f.get(cfg)),
                            enabled = f.enabled(edit),
                        ) { boolEdits[f.label] = it }
                    }
                }
            }
        }
    }
}

/**
 * Whether the machine the engine runs on has a GPU star can use, and which (macOS `Config.gpuAccelerationStatusText`). Not a setting, so there is
 * nothing to toggle here.
 */
@Composable
private fun GPUHardwareStatusRow(available: Boolean, device: String?) {
    Text(
        if (available) localized("ui.gpu_status_supported", device ?: "GPU") else localized("ui.gpu_status_unsupported"),
        color = StarColors.textDisabled, fontSize = 10.sp,
    )
}

/**
 * A label and a box for a number. A value that is not in range marks the box red and says what the range is, under it; a row that does not apply
 * is greyed and cannot be edited.
 */
@Composable
private fun NumberRow(label: String, value: String, enabled: Boolean, problem: String?, onChange: (String) -> Unit) {
    val shownProblem = problem.takeIf { enabled }
    Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(label, color = if (enabled) StarColors.textPrimary else StarColors.textDisabled, fontSize = 12.sp, modifier = Modifier.weight(1f))
            BasicTextField(
                value = value,
                onValueChange = onChange,
                enabled = enabled,
                singleLine = true,
                textStyle = TextStyle(fontSize = 12.sp, color = if (enabled) StarColors.textPrimary else StarColors.textDisabled),
                cursorBrush = SolidColor(StarColors.white),
                modifier = Modifier
                    .widthIn(min = 90.dp, max = 110.dp)
                    .clip(RoundedCornerShape(4.dp))
                    .background(StarColors.sidePanel)
                    .border(1.dp, if (shownProblem != null) StarColors.red else StarColors.cellDefault, RoundedCornerShape(4.dp))
                    .padding(horizontal = 8.dp, vertical = 6.dp),
            )
        }
        if (shownProblem != null) Text(shownProblem, color = StarColors.red, fontSize = 10.sp, modifier = Modifier.align(Alignment.End))
    }
}
