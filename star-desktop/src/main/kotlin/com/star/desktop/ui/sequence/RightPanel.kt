package com.star.desktop.ui.sequence

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.star.desktop.domain.FastAdvancementType
import com.star.desktop.domain.ToolType
import com.star.desktop.domain.usesOutliers
import com.star.desktop.ui.components.HoverTip
import com.star.desktop.ui.components.toolPainter
import com.star.desktop.ui.sequence.edit.FrameTransform
import com.star.desktop.ui.theme.StarColors
import com.star.proto.CleanMethod
import com.star.proto.ReprocessingType
import com.star.desktop.i18n.localized

/**
 * Right panel (macOS `RightPanel`): the editing tool picker. Tool *paint* behavior is wired in
 * Phase 4 (outlier editing); this presents the 8 tools (shortcuts 1–8) with selection highlight.
 */
@Composable
fun RightPanel(app: com.star.desktop.ui.app.AppViewModel, vm: SequenceViewModel, modifier: Modifier = Modifier) {
    val tool by vm.tool.collectAsState()
    val current by vm.currentIndex.collectAsState()
    val fvm = androidx.compose.runtime.remember(current) { vm.frameVMFor(current) }
    val groups by fvm.groups.collectAsState()
    val decisions by fvm.decisions.collectAsState()
    val selection by fvm.selection.collectAsState()
    val info by fvm.info.collectAsState()
    val fastAdv by vm.fastAdvancement.collectAsState()
    val onlyUnclassified by vm.classifyOnlyUnclassified.collectAsState()
    var showToolHelp by androidx.compose.runtime.remember { androidx.compose.runtime.mutableStateOf(false) }

    Column(modifier.width(150.dp).fillMaxHeight().background(StarColors.sidePanel)) {
      Column(
        modifier = Modifier
            .weight(1f)
            .fillMaxWidth()
            .verticalScroll(rememberScrollState())
            .padding(8.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        // Selective-removal tools (remove/keep/razor/shovel/...) only apply when this frame's
        // clean method actually reviews outliers (macOS `currentFrameUsesOutliers`) — plain
        // automatic mode replaces every bad pixel with no per-frame review, so there is nothing
        // for these tools to act on.
        val usesOutliers = (info?.cleanMethod ?: CleanMethod.CLEAN_SELECTIVE).usesOutliers
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            Text(localized("menu.tools"), color = StarColors.textPrimary, fontWeight = FontWeight.SemiBold, fontSize = 13.sp)
            ToolHelpButton { showToolHelp = true }
        }
        if (showToolHelp) com.star.desktop.ui.dialogs.ToolHelpDialog(onClose = { showToolHelp = false })
        ToolType.selectable.forEachIndexed { i, t ->
            ToolRow(t, number = i + 1, selected = t == tool, enabled = usesOutliers, onClick = { vm.setTool(t) })
        }
        // With this on, clicking a group that has a decision opens the multi-choice sheet whatever the tool (macOS "multi choice").
        val multiChoice by vm.multiChoiceMode.collectAsState()
        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
            androidx.compose.material3.Switch(checked = multiChoice, onCheckedChange = vm::setMultiChoiceMode, enabled = usesOutliers)
            Spacer(Modifier.width(6.dp))
            Text(localized("ui.multi_choice"), color = StarColors.white, fontSize = 11.sp)
        }

        androidx.compose.material3.HorizontalDivider(color = StarColors.cellDefault, modifier = Modifier.padding(vertical = 4.dp))

        val remove = groups.count { com.star.desktop.domain.OutlierDecisions.willRemove(decisions[it.id] ?: it.shouldRemove) == true }
        val keep = groups.count { com.star.desktop.domain.OutlierDecisions.willRemove(decisions[it.id] ?: it.shouldRemove) == false }
        val undecided = groups.size - remove - keep
        Text(localized("ui.outliers_count", groups.size), color = StarColors.textPrimary, fontWeight = FontWeight.SemiBold, fontSize = 12.sp)
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Text("✕$remove", color = StarColors.red, fontSize = 11.sp)
            Text("✓$keep", color = StarColors.green, fontSize = 11.sp)
            Text("?$undecided", color = StarColors.orange, fontSize = 11.sp)
        }
        val showTrash by vm.showTrash.collectAsState()
        // The trash, and what is in it: shown over the frame and, while it is, taken in by the tools below.
        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
            androidx.compose.material3.Switch(checked = showTrash, onCheckedChange = vm::setShowTrash, enabled = usesOutliers)
            Spacer(Modifier.width(6.dp))
            Text(localized("ui.show_trash"), color = StarColors.white, fontSize = 11.sp)
        }
        info?.let { if (it.numTrashOutliers > 0) Text("${localized("ui.trash")}: ${it.numTrashOutliers}", color = StarColors.gray, fontSize = 11.sp) }
        BulkButton(localized("ui.keep_all"), StarColors.green, help = localized("ui.keep_all_of_the_outlier_groups_in_the_frame")) { fvm.keepAll(showTrash) }
        BulkButton(localized("ui.remove_all"), StarColors.red, help = localized("ui.remove_all_of_the_outlier_groups_in_the")) { fvm.removeAll(showTrash) }
        BulkButton(localized("ui.clear_undecided"), StarColors.gray) { fvm.clearUndecided(showTrash) }
        BulkButton(
            localized("ui.decision_tree_all"), StarColors.blue,
            help = localized("ui.apply_the_outlier_group_decision_tree_to_all"), enabled = usesOutliers,
        ) { vm.applyDecisionTreeToCurrentFrame() }
        BulkButton(
            localized("ui.dt_auto_only"), StarColors.blue,
            help = localized("ui.apply_the_outlier_group_decision_tree_to_all_2"), enabled = usesOutliers,
        ) { vm.applyDecisionTreeToCurrentFrame(autoOnly = true) }
        BulkButton(localized("ui.decision_tree_all_frames"), StarColors.blue, enabled = usesOutliers) { vm.applyDecisionTreeAll() }
        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
            androidx.compose.material3.Checkbox(checked = onlyUnclassified, onCheckedChange = { vm.setClassifyOnlyUnclassified(it) })
            Text(localized("ui.only_unclassified"), color = StarColors.orange, fontSize = 11.sp)
        }
        selection.singleOrNull()?.let { Text(localized("ui.selected_number", it), color = StarColors.orange, fontSize = 10.sp) }

        androidx.compose.material3.HorizontalDivider(color = StarColors.cellDefault, modifier = Modifier.padding(vertical = 4.dp))
        // Horizon painting (macOS RightPanel): open or close the painter, and show the horizon line on the frame, the
        // filmstrip and the grid.
        val painting by vm.horizonPaintMode.collectAsState()
        BulkButton(
            localized(if (painting) "ui.close_horizon_painter" else "ui.paint_horizon_reference"),
            if (painting) StarColors.red else StarColors.blue,
        ) { vm.toggleHorizonPaint() }
        val showHorizon by vm.showHorizonOnMainView.collectAsState()
        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
            androidx.compose.material3.Switch(checked = showHorizon, onCheckedChange = vm::setShowHorizonOnMainView)
            Spacer(Modifier.width(6.dp))
            Text(localized("ui.show_horizon_line"), color = StarColors.white, fontSize = 11.sp)
        }
        HorizonLineKindToggles(vm)
        val refinementPending by vm.refinementPending.collectAsState()
        val busy by vm.isProcessing.collectAsState()
        BulkButton(
            localized("ui.re_run_horizon_refinement"), StarColors.orange,
            help = localized("ui.re_run_brightness_position_refinement_for"), enabled = refinementPending && !busy,
        ) { vm.runHorizonRefinement() }

        androidx.compose.material3.HorizontalDivider(color = StarColors.cellDefault, modifier = Modifier.padding(vertical = 4.dp))
        // How strongly the outlier groups, the trash and the frame itself are drawn (macOS: three sliders, in memory only).
        val outlierOpacity by vm.outlierOpacity.collectAsState()
        val trashOpacity by vm.trashOpacity.collectAsState()
        val frameOpacity by vm.frameOpacity.collectAsState()
        OpacitySlider(localized("ui.outlier_group_opacity"), outlierOpacity, vm::setOutlierOpacity, usesOutliers)
        OpacitySlider(localized("ui.trash_opacity"), trashOpacity, vm::setTrashOpacity, usesOutliers)
        OpacitySlider(localized("ui.frame_opacity"), frameOpacity, vm::setFrameOpacity, usesOutliers)

        androidx.compose.material3.HorizontalDivider(color = StarColors.cellDefault, modifier = Modifier.padding(vertical = 4.dp))
        ZoomControls(vm)
        val fullResolution by vm.showFullResolution.collectAsState()
        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
            androidx.compose.material3.Switch(checked = fullResolution, onCheckedChange = vm::setShowFullResolution)
            Spacer(Modifier.width(6.dp))
            Text(localized("ui.show_full_resolution"), color = StarColors.white, fontSize = 11.sp)
        }

        androidx.compose.material3.HorizontalDivider(color = StarColors.cellDefault, modifier = Modifier.padding(vertical = 4.dp))
        Text(localized("ui.clean_method"), color = StarColors.textPrimary, fontWeight = FontWeight.SemiBold, fontSize = 12.sp)
        val activeMethod = info?.cleanMethod ?: CleanMethod.CLEAN_SELECTIVE
        // Whether the method is this frame's own or the sequence's (macOS Custom / Default).
        Text(
            localized(if (info?.cleanMethodOverridden == true) "ui.custom" else "ui.default"),
            color = StarColors.white, fontSize = 11.sp,
        )
        val cmLabels = CLEAN_METHODS.toMap()
        com.star.desktop.ui.components.VerticalStarPicker(
            options = CLEAN_METHODS.map { it.first },
            selected = activeMethod,
            label = { cmLabels[it]?.let { key -> localized(key) } ?: "" },
            onSelect = { fvm.setCleanMethod(it) },
            modifier = Modifier.fillMaxWidth(),
        )
        // How many neighbours this frame is merged with for the horizon (a fixed camera only), the sequence's number until the frame is
        // given its own. macOS dropped the matching "align with N neighbor frames" row, so it is not here either; the daemon still
        // takes an aligned count (Frame.SetNeighborOverride).
        val session by app.sessions.session.collectAsState()
        info?.let { i ->
            if (session?.config?.tripodHeadWasMoving != true) {
                NeighborCountEditor(
                    prefixKey = "ui.slider.static_merge", suffixKey = "ui.slider.neighbors",
                    count = i.staticNeighborCount, overridden = i.staticNeighborOverridden, max = vm.frameCount - 1, frame = current,
                    onCommit = { vm.setNeighborOverride(com.star.proto.NeighborKind.NEIGHBOR_STATIC, it) },
                    onReset = { vm.setNeighborOverride(com.star.proto.NeighborKind.NEIGHBOR_STATIC, null) },
                )
            }
        }

        androidx.compose.material3.HorizontalDivider(color = StarColors.cellDefault, modifier = Modifier.padding(vertical = 4.dp))
        // How the fast buttons (z / x) move, and what they do in the strategy chosen (macOS "Fast Advancement Type").
        Text(localized("ui.fast_advancement_type"), color = StarColors.textPrimary, fontWeight = FontWeight.SemiBold, fontSize = 12.sp)
        com.star.desktop.ui.components.VerticalStarPicker(
            options = FastAdvancementType.entries,
            selected = fastAdv,
            label = { it.label },
            onSelect = { vm.setFastAdvancement(it) },
            modifier = Modifier.fillMaxWidth(),
        )
        val skipAmount by vm.fastSkipAmount.collectAsState()
        Text(fastAdv.description(skipAmount), color = StarColors.textSecondary, fontSize = 10.sp)
        if (fastAdv == FastAdvancementType.NORMAL) {
            Text(localized("ui.fast_skip"), color = StarColors.textPrimary, fontSize = 11.sp)
            androidx.compose.material3.Slider(
                value = skipAmount.toFloat(),
                onValueChange = { vm.setFastSkipAmount(it.toInt()) },
                valueRange = 0f..FastAdvancementType.MAX_SKIP_AMOUNT.toFloat(),
                steps = FastAdvancementType.MAX_SKIP_AMOUNT - 1,
                modifier = Modifier.fillMaxWidth(),
            )
            Text(localized("ui.n_frames_lower", skipAmount), color = StarColors.textSecondary, fontSize = 10.sp)
        }

        androidx.compose.material3.HorizontalDivider(color = StarColors.cellDefault, modifier = Modifier.padding(vertical = 4.dp))
        ReprocessControls(app, vm)
        // macOS keeps the log-to-file switch at the foot of this panel.
        com.star.desktop.ui.windows.LogToFileControls(app.debugLog)
      }
      com.star.desktop.ui.components.PanelChevron("»", { vm.setRightPanel(false) }, Modifier.padding(6.dp))
    }
}

/**
 * "Re-process the next N frames" (macOS RightPanel): what to throw away first, the button that processes from this frame on, how many
 * frames, and the detection strength they are processed with; and "Render Updates", which writes this frame's decisions into its image.
 */
@Composable
private fun ReprocessControls(app: com.star.desktop.ui.app.AppViewModel, vm: SequenceViewModel) {
    val type by vm.reprocessType.collectAsState()
    val processing by vm.isProcessing.collectAsState()
    val rendering by vm.rendering.collectAsState()
    val busy = processing || rendering
    val frames by vm.framesToProcess.collectAsState()
    val session by app.sessions.session.collectAsState()
    val current by vm.currentIndex.collectAsState()
    val info by vm.frameVMFor(current).info.collectAsState()

    Text(localized("ui.redo"), color = StarColors.textPrimary, fontWeight = FontWeight.SemiBold, fontSize = 12.sp)
    com.star.desktop.ui.components.VerticalStarPicker(
        options = REDO_TYPES,
        selected = type,
        label = { redoLabel(it) },
        onSelect = vm::setReprocessType,
        modifier = Modifier.fillMaxWidth(),
    )
    BulkButton(
        localized(when (type) {
            ReprocessingType.REPROCESS_NONE -> "ui.process_the_next"
            ReprocessingType.REPROCESS_ALL_HORIZONS -> "ui.re_process_all_horizons"
            else -> "ui.re_process_the_next"
        }),
        StarColors.orange, enabled = !busy,
    ) { vm.reprocessNext() }
    if (type != ReprocessingType.REPROCESS_ALL_HORIZONS) {
        var text by androidx.compose.runtime.remember(frames) { androidx.compose.runtime.mutableStateOf(frames.toString()) }
        val parsed = text.toIntOrNull()
        val valid = parsed != null && parsed in 1..vm.frameCount
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            androidx.compose.foundation.text.BasicTextField(
                value = text,
                onValueChange = { text = it.filter(Char::isDigit); text.toIntOrNull()?.takeIf { n -> n in 1..vm.frameCount }?.let(vm::setFramesToProcess) },
                singleLine = true,
                textStyle = androidx.compose.ui.text.TextStyle(color = if (valid) StarColors.white else StarColors.red, fontSize = 11.sp),
                cursorBrush = SolidColor(StarColors.white),
                modifier = Modifier.width(44.dp).clip(RoundedCornerShape(3.dp)).background(StarColors.cellDefault).padding(horizontal = 4.dp, vertical = 2.dp),
            )
            Text(localized(if (frames == 1) "ui.slider.frame_as" else "ui.slider.frames_as"), color = StarColors.white, fontSize = 11.sp)
        }
        val detection = session?.config?.detectionType ?: com.star.proto.DetectionType.DETECTION_STRONG
        com.star.desktop.ui.components.VerticalStarPicker(
            options = DETECTION_TYPES,
            selected = detection,
            label = { localized("detection_type." + it.name.removePrefix("DETECTION_").lowercase()) },
            onSelect = app::setDetectionType,
            modifier = Modifier.fillMaxWidth(),
        )
    }
    // Writes the frame's decisions into its finished image; there is nothing to write until its outliers are loaded.
    BulkButton(localized("ui.render_updates"), StarColors.blue, enabled = info?.outliersLoaded == true && !rendering) { vm.renderCurrentFrame() }
}

/** What the redo picker can clear first (macOS `FrameReprocessingType`), in macOS's order. */
private val REDO_TYPES = listOf(
    ReprocessingType.REPROCESS_EVERYTHING, ReprocessingType.REPROCESS_ALIGNMENT, ReprocessingType.REPROCESS_OUTLIERS,
    ReprocessingType.REPROCESS_HORIZONS, ReprocessingType.REPROCESS_ALL_HORIZONS, ReprocessingType.REPROCESS_NONE,
)

private fun redoLabel(t: ReprocessingType): String = localized(when (t) {
    ReprocessingType.REPROCESS_EVERYTHING -> "ui.re_process_everything"
    ReprocessingType.REPROCESS_ALIGNMENT -> "ui.re_process_alignment"
    ReprocessingType.REPROCESS_OUTLIERS -> "ui.re_process_outliers"
    ReprocessingType.REPROCESS_HORIZONS -> "ui.re_process_horizons"
    ReprocessingType.REPROCESS_ALL_HORIZONS -> "ui.re_process_all_horizons"
    else -> "ui.redo_none"
})

private val DETECTION_TYPES = listOf(
    com.star.proto.DetectionType.DETECTION_MILD, com.star.proto.DetectionType.DETECTION_STRONG,
    com.star.proto.DetectionType.DETECTION_STRONGER, com.star.proto.DetectionType.DETECTION_EXCESSIVE, com.star.proto.DetectionType.DETECTION_CUSTOM,
)

/**
 * A number of neighbour frames for the frame being looked at (macOS `AlignedNeighborFrameOverrideView` / `StaticNeighborFrameOverrideView`):
 * "[prefix] N [suffix]", in yellow once it is the frame's own, with a Reset that gives the sequence's number back. Return, or leaving the
 * field, sets it if it is a whole number from 1 to [max]; anything else puts the number back.
 */
@Composable
private fun NeighborCountEditor(
    prefixKey: String, suffixKey: String, count: Int, overridden: Boolean, max: Int, frame: Int,
    onCommit: (Int) -> Unit, onReset: () -> Unit,
) {
    var text by androidx.compose.runtime.remember(frame, count) { androidx.compose.runtime.mutableStateOf(count.toString()) }
    fun commit() {
        val n = text.toIntOrNull()
        if (n == null || n !in 1..max.coerceAtLeast(1)) { text = count.toString(); return }
        if (n != count) onCommit(n)
    }
    val color = if (overridden) StarColors.yellow else StarColors.white
    Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
        if (overridden) {
            androidx.compose.material3.OutlinedButton(
                onClick = onReset,
                colors = androidx.compose.material3.ButtonDefaults.outlinedButtonColors(contentColor = StarColors.orange),
                contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = 8.dp, vertical = 0.dp),
            ) { Text(localized("ui.reset"), fontSize = 10.sp) }
        }
        Text(localized(prefixKey), color = color, fontSize = 11.sp)
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            androidx.compose.foundation.text.BasicTextField(
                value = text,
                onValueChange = { text = it.filter(Char::isDigit) },
                singleLine = true,
                textStyle = androidx.compose.ui.text.TextStyle(color = color, fontSize = 11.sp),
                cursorBrush = SolidColor(color),
                modifier = Modifier
                    .width(44.dp)
                    .clip(RoundedCornerShape(3.dp))
                    .background(StarColors.cellDefault)
                    .padding(horizontal = 4.dp, vertical = 2.dp)
                    .onPreviewKeyEvent { e ->
                        if (e.type == androidx.compose.ui.input.key.KeyEventType.KeyDown &&
                            (e.key == androidx.compose.ui.input.key.Key.Enter || e.key == androidx.compose.ui.input.key.Key.NumPadEnter)
                        ) { commit(); true } else false
                    }
                    .onFocusChanged { if (!it.isFocused) commit() },
            )
            Text(localized(suffixKey), color = color, fontSize = 11.sp)
        }
    }
}

/** Per-frame clean methods (proto `CleanMethod`) with the catalogue key of the label, as in the macOS picker. */
private val CLEAN_METHODS: List<Pair<CleanMethod, String>> = listOf(
    CleanMethod.CLEAN_AUTOMATIC to "ui.automatic",
    CleanMethod.CLEAN_AUTOMATIC_TRUE to "ui.auto_selective",
    CleanMethod.CLEAN_SELECTIVE to "ui.selective",
)

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun BulkButton(label: String, color: Color, help: String? = null, enabled: Boolean = true, onClick: () -> Unit) {
    val button = @Composable {
        androidx.compose.material3.OutlinedButton(
            onClick = onClick,
            enabled = enabled,
            colors = androidx.compose.material3.ButtonDefaults.outlinedButtonColors(contentColor = color),
            contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = 8.dp, vertical = 4.dp),
            modifier = Modifier.fillMaxWidth(),
        ) { Text(label, fontSize = 11.sp) }
    }
    if (help != null) HoverTip(help, button) else button()
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun ToolRow(tool: ToolType, number: Int, selected: Boolean, enabled: Boolean = true, onClick: () -> Unit) {
    val accent = StarColors.toolColor(tool)
    val alpha = if (enabled) 1f else 0.35f
    HoverTip(if (enabled) tool.helpText else localized("tool.help.disabled")) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(5.dp))
            .background(if (selected && enabled) accent.copy(alpha = 0.22f) else Color.Transparent)
            .then(if (selected && enabled) Modifier.border(1.dp, SolidColor(accent), RoundedCornerShape(5.dp)) else Modifier)
            .clickable(enabled = enabled, onClick = onClick)
            .padding(4.dp)
            .alpha(alpha),
    ) {
        Icon(
            painter = toolPainter(tool),
            contentDescription = tool.displayName,
            tint = Color.Unspecified,
            modifier = Modifier.size(28.dp),
        )
        Column {
            Text(tool.displayName, color = StarColors.textPrimary, fontSize = 11.sp)
            Text("$number", color = StarColors.textDisabled, fontSize = 9.sp)
        }
    }
    }
}

/** The circled "i" that opens the detailed tool explanation. */
@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun ToolHelpButton(onClick: () -> Unit) {
    HoverTip(localized("ui.tool_help_button")) {
        Box(
            Modifier
                .size(16.dp)
                .clip(CircleShape)
                .border(1.dp, SolidColor(StarColors.textPrimary), CircleShape)
                .clickable(onClick = onClick),
            contentAlignment = Alignment.Center,
        ) { Text("i", color = StarColors.textPrimary, fontSize = 10.sp, fontWeight = FontWeight.Bold) }
    }
}

/**
 * Zoom (macOS RightPanel): a slider from fit up to the maximum, and the maximum itself, editable ("Max: 1" = 100%, up to
 * 10). The same transform the wheel, Ctrl-wheel and double-click change, so the slider follows them.
 */
@Composable
private fun ZoomControls(vm: SequenceViewModel) {
    val t = vm.transform
    val canvas = t.canvas
    val fit = t.baseScale(canvas)
    val limit = maxOf(fit, t.maxScale)
    val scale = t.scale(canvas).coerceIn(fit, limit)
    var maxText by androidx.compose.runtime.remember(t.maxScale) { androidx.compose.runtime.mutableStateOf(formatScale(t.maxScale)) }
    val parsed = maxText.toFloatOrNull()
    val valid = parsed != null && parsed >= fit.coerceAtLeast(FrameTransform.MIN_MAX_SCALE) && parsed <= FrameTransform.MAX_SCALE_LIMIT

    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.SpaceBetween) {
        Text(localized("ui.zoom"), color = StarColors.textPrimary, fontWeight = FontWeight.SemiBold, fontSize = 12.sp)
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(localized("ui.slider.max_zoom_prefix"), color = StarColors.textSecondary, fontSize = 11.sp)
            androidx.compose.foundation.text.BasicTextField(
                value = maxText,
                onValueChange = {
                    maxText = it
                    it.toFloatOrNull()?.let { v -> if (v >= fit && v <= FrameTransform.MAX_SCALE_LIMIT) t.setMaxScale(v, canvas) }
                },
                singleLine = true,
                textStyle = androidx.compose.ui.text.TextStyle(color = if (valid) StarColors.white else StarColors.red, fontSize = 11.sp),
                cursorBrush = SolidColor(StarColors.white),
                modifier = Modifier
                    .width(40.dp)
                    .clip(RoundedCornerShape(3.dp))
                    .background(StarColors.cellDefault)
                    .padding(horizontal = 4.dp, vertical = 2.dp),
            )
        }
    }
    androidx.compose.material3.Slider(
        value = scale,
        onValueChange = { t.setScale(it, canvas) },
        valueRange = fit..(limit.coerceAtLeast(fit + 1e-4f)),
        enabled = limit - fit > 1e-4f,
        modifier = Modifier.fillMaxWidth(),
    )
}

/** One of the opacity sliders: its name, and 0 to 1. */
@Composable
private fun OpacitySlider(label: String, value: Float, onChange: (Float) -> Unit, enabled: Boolean) {
    Text(label, color = StarColors.textPrimary, fontSize = 11.sp)
    androidx.compose.material3.Slider(value = value, onValueChange = onChange, valueRange = 0f..1f, enabled = enabled, modifier = Modifier.fillMaxWidth())
}

/** A scale for the Max field: "1", "2.5", not "1.0000". */
internal fun formatScale(v: Float): String = if (v == v.toInt().toFloat()) v.toInt().toString() else "%.2f".format(java.util.Locale.ROOT, v).trimEnd('0').trimEnd('.')
