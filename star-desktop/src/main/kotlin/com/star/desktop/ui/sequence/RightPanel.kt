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
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.star.desktop.ui.components.numberFieldRules
import com.star.desktop.domain.FastAdvancementType
import com.star.desktop.domain.ToolType
import com.star.desktop.domain.usesOutliers
import com.star.desktop.ui.components.HoverTip
import com.star.desktop.ui.components.toolPainter
import com.star.desktop.ui.sequence.edit.FrameTransform
import com.star.desktop.ui.theme.StarColors
import com.star.proto.CleanMethod
import com.star.desktop.i18n.localized

/**
 * Right panel (macOS `RightPanel`), in labelled sections split by dividers: the selective tools (only while this frame's clean
 * method reviews outliers), what changes its processing, and debug. Every section and control has
 * hover help.
 */
@Composable
fun RightPanel(app: com.star.desktop.ui.app.AppViewModel, vm: SequenceViewModel, modifier: Modifier = Modifier) {
    val current by vm.currentIndex.collectAsState()
    val fvm = androidx.compose.runtime.remember(current) { vm.frameVMFor(current) }
    val info by fvm.info.collectAsState()

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
        // for these tools to act on, and the whole section is left out.
        val usesOutliers = (info?.cleanMethod ?: CleanMethod.CLEAN_SELECTIVE).usesOutliers
        if (usesOutliers) {
            CollapsibleSection(vm, RightPanelSection.SELECTIVE_TOOLS, localized("ui.section.selective_tools"), localized("ui.section.selective_tools_help")) {
                SelectiveToolsSection(vm, fvm)
            }
            SectionDivider()
        }
        CollapsibleSection(vm, RightPanelSection.PROCESSING, localized("ui.processing"), localized("ui.section.processing_help")) {
            ProcessingSection(app, vm, fvm)
        }
        SectionDivider()
        CollapsibleSection(vm, RightPanelSection.DEBUG, localized("ui.section.debug"), localized("ui.section.debug_help")) {
            // macOS keeps the log-to-file switch at the foot of this panel.
            HoverTip(localized("ui.log_to_file_help")) {
                Column { com.star.desktop.ui.windows.LogToFileControls(app.debugLog) }
            }
        }
      }
      com.star.desktop.ui.components.PanelChevron("»", { vm.setRightPanel(false) }, Modifier.padding(6.dp))
    }
}

/** The tools for deciding by hand which outliers go and which stay, and how the outliers and the trash are drawn. */
@Composable
private fun SelectiveToolsSection(vm: SequenceViewModel, fvm: FrameViewModel) {
    val tool by vm.tool.collectAsState()
    val groups by fvm.groups.collectAsState()
    val decisions by fvm.decisions.collectAsState()
    val selection by fvm.selection.collectAsState()
    val info by fvm.info.collectAsState()
    val onlyUnclassified by vm.classifyOnlyUnclassified.collectAsState()
    var showToolHelp by androidx.compose.runtime.remember { androidx.compose.runtime.mutableStateOf(false) }

    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        HoverTip(localized("ui.tool_help")) {
            Text(localized("menu.tools"), color = StarColors.textPrimary, fontWeight = FontWeight.SemiBold, fontSize = 12.sp)
        }
        ToolHelpButton { showToolHelp = true }
    }
    if (showToolHelp) com.star.desktop.ui.dialogs.ToolHelpDialog(onClose = { showToolHelp = false })
    ToolType.selectable.forEachIndexed { i, t ->
        ToolRow(t, number = i + 1, selected = t == tool, onClick = { vm.setTool(t) })
    }
    // With this on, clicking a group that has a decision opens the multi-choice sheet whatever the tool (macOS "multi choice").
    val multiChoice by vm.multiChoiceMode.collectAsState()
    SwitchRow(localized("ui.multi_choice"), localized("ui.multi_choice_help"), multiChoice, vm::setMultiChoiceMode)

    val remove = groups.count { com.star.desktop.domain.OutlierDecisions.willRemove(decisions[it.id] ?: it.shouldRemove) == true }
    val keep = groups.count { com.star.desktop.domain.OutlierDecisions.willRemove(decisions[it.id] ?: it.shouldRemove) == false }
    val undecided = groups.size - remove - keep
    HoverTip(localized("ui.outlier_counts_help")) {
        Column {
            Text(localized("ui.outliers_count", groups.size), color = StarColors.textPrimary, fontWeight = FontWeight.SemiBold, fontSize = 12.sp)
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Text("✕$remove", color = StarColors.red, fontSize = 11.sp)
                Text("✓$keep", color = StarColors.green, fontSize = 11.sp)
                Text("?$undecided", color = StarColors.orange, fontSize = 11.sp)
            }
        }
    }
    val showTrash by vm.showTrash.collectAsState()
    // The trash, and what is in it: shown over the frame and, while it is, taken in by the tools below.
    SwitchRow(localized("ui.show_trash"), localized("ui.show_trash_help"), showTrash, vm::setShowTrash)
    info?.let { if (it.numTrashOutliers > 0) Text("${localized("ui.trash")}: ${it.numTrashOutliers}", color = StarColors.gray, fontSize = 11.sp) }
    BulkButton(localized("ui.keep_all"), StarColors.green, help = localized("ui.keep_all_of_the_outlier_groups_in_the_frame")) { fvm.keepAll(showTrash) }
    BulkButton(localized("ui.remove_all"), StarColors.red, help = localized("ui.remove_all_of_the_outlier_groups_in_the")) { fvm.removeAll(showTrash) }
    BulkButton(localized("ui.clear_undecided"), StarColors.gray, help = localized("ui.don_t_paint_any_of_the_undecided_outlier")) { fvm.clearUndecided(showTrash) }
    BulkButton(
        localized("ui.decision_tree_all"), StarColors.blue,
        help = localized("ui.apply_the_outlier_group_decision_tree_to_all"),
    ) { vm.applyDecisionTreeToCurrentFrame() }
    BulkButton(
        localized("ui.dt_auto_only"), StarColors.blue,
        help = localized("ui.apply_the_outlier_group_decision_tree_to_all_2"),
    ) { vm.applyDecisionTreeToCurrentFrame(autoOnly = true) }
    BulkButton(
        localized("ui.decision_tree_all_frames"), StarColors.blue,
        help = localized("ui.decision_tree_all_frames_help"),
    ) { vm.applyDecisionTreeAll() }
    HoverTip(localized("ui.only_unclassified_help")) {
        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
            androidx.compose.material3.Checkbox(checked = onlyUnclassified, onCheckedChange = { vm.setClassifyOnlyUnclassified(it) })
            Text(localized("ui.only_unclassified"), color = StarColors.orange, fontSize = 11.sp)
        }
    }
    selection.singleOrNull()?.let { Text(localized("ui.selected_number", it), color = StarColors.orange, fontSize = 10.sp) }

    // How strongly the outlier groups and the trash are drawn (macOS: sliders, in memory only).
    val outlierOpacity by vm.outlierOpacity.collectAsState()
    val trashOpacity by vm.trashOpacity.collectAsState()
    OpacitySlider(localized("ui.outlier_group_opacity"), localized("ui.outlier_group_opacity_help"), outlierOpacity, vm::setOutlierOpacity)
    OpacitySlider(localized("ui.trash_opacity"), localized("ui.trash_opacity_help"), trashOpacity, vm::setTrashOpacity)
}

/** How the frame is shown and stepped through; nothing here changes the processed output. */
@Composable
internal fun DisplaySection(vm: SequenceViewModel) {
    val fastAdv by vm.fastAdvancement.collectAsState()

    // How the fast buttons (z / x) move, and what they do in the strategy chosen (macOS "Fast Advancement Type").
    val skipAmount by vm.fastSkipAmount.collectAsState()
    HoverTip(localized("ui.fast_advancement_type_help")) {
        Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Text(localized("ui.fast_advancement_type"), color = StarColors.textPrimary, fontSize = 11.sp)
            com.star.desktop.ui.components.VerticalStarPicker(
                options = FastAdvancementType.entries,
                selected = fastAdv,
                label = { it.label },
                onSelect = { vm.setFastAdvancement(it) },
                modifier = Modifier.fillMaxWidth(),
            )
            Text(fastAdv.description(skipAmount), color = StarColors.textSecondary, fontSize = 10.sp)
        }
    }
    if (fastAdv == FastAdvancementType.NORMAL) {
        HoverTip(localized("ui.fast_skip_help")) {
            Column {
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
        }
    }

    // The horizon line on the frame, the filmstrip and the grid, and which kinds of it.
    val showHorizon by vm.showHorizonOnMainView.collectAsState()
    HoverTip(localized("ui.show_horizon_line_help")) {
        Column {
            SwitchRow(localized("ui.show_horizon_line"), null, showHorizon, vm::setShowHorizonOnMainView)
            HorizonLineKindToggles(vm)
        }
    }

    // Not tied to the outliers like the two in the selective tools: it dims the frame itself, which helps in every clean mode.
    val frameOpacity by vm.frameOpacity.collectAsState()
    OpacitySlider(localized("ui.frame_opacity"), localized("ui.frame_opacity_help"), frameOpacity, vm::setFrameOpacity)

    HoverTip(localized("ui.zoom_help")) {
        Column { ZoomControls(vm) }
    }
    val fullResolution by vm.showFullResolution.collectAsState()
    SwitchRow(localized("ui.show_full_resolution"), localized("ui.show_full_resolution_help"), fullResolution, vm::setShowFullResolution)
}

/** What changes how frames are processed: the horizon reference, the clean method, the static merge and rendering. */
@Composable
private fun ProcessingSection(app: com.star.desktop.ui.app.AppViewModel, vm: SequenceViewModel, fvm: FrameViewModel) {
    val current by vm.currentIndex.collectAsState()
    val info by fvm.info.collectAsState()

    // Horizon painting (macOS RightPanel): open or close the painter, and re-run the refinement it feeds.
    val painting by vm.horizonPaintMode.collectAsState()
    BulkButton(
        localized(if (painting) "ui.close_horizon_painter" else "ui.paint_horizon_reference"),
        if (painting) StarColors.red else StarColors.blue,
        help = localized("ui.paint_horizon_reference_help"),
    ) { vm.toggleHorizonPaint() }
    val refinementPending by vm.refinementPending.collectAsState()
    val busy by vm.isProcessing.collectAsState()
    BulkButton(
        localized("ui.re_run_horizon_refinement"), StarColors.orange,
        help = localized("ui.re_run_brightness_position_refinement_for"), enabled = refinementPending && !busy,
    ) { vm.runHorizonRefinement() }

    val activeMethod = info?.cleanMethod ?: CleanMethod.CLEAN_SELECTIVE
    // The mode is changed from a dialog that only applies it on OK (macOS ChangeProcessingModeView), not from toggles in the panel.
    var showChangeMode by androidx.compose.runtime.remember { androidx.compose.runtime.mutableStateOf(false) }
    val modeName = localized(com.star.desktop.ui.dialogs.frameModeNameKey(activeMethod))
    HoverTip(localized("ui.clean_method_help")) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(
                localized(if (info?.cleanMethodOverridden == true) "ui.processing_mode_current_custom" else "ui.processing_mode_current_default", modeName),
                color = StarColors.white, fontSize = 11.sp, modifier = Modifier.weight(1f),
            )
            androidx.compose.material3.OutlinedButton(
                onClick = { showChangeMode = true },
                contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = 8.dp, vertical = 4.dp),
            ) { Text(localized("ui.change_mode"), fontSize = 11.sp) }
        }
    }
    if (showChangeMode) {
        com.star.desktop.ui.dialogs.ChangeProcessingModeDialog(
            current = activeMethod,
            onCancel = { showChangeMode = false },
            onConfirm = { fvm.setCleanMethod(it); showChangeMode = false },
        )
    }
    // How many neighbours this frame is merged with for the horizon (a fixed camera only), the sequence's number until the frame is
    // given its own. macOS dropped the matching "align with N neighbor frames" row, so it is not here either; the daemon still
    // takes an aligned count (Frame.SetNeighborOverride).
    val session by app.sessions.session.collectAsState()
    info?.let { i ->
        if (session?.config?.tripodHeadWasMoving != true) {
            HoverTip(localized("ui.static_merge_help")) {
                NeighborCountEditor(
                    prefixKey = "ui.slider.static_merge", suffixKey = "ui.slider.neighbors",
                    count = i.staticNeighborCount, overridden = i.staticNeighborOverridden, max = vm.frameCount - 1, frame = current,
                    onCommit = { vm.setNeighborOverride(com.star.proto.NeighborKind.NEIGHBOR_STATIC, it) },
                    onReset = { vm.setNeighborOverride(com.star.proto.NeighborKind.NEIGHBOR_STATIC, null) },
                )
            }
        }
    }

    // Writes the frame's decisions into its finished image; there is nothing to write until its outliers are loaded.
    // (macOS dropped the "re-process the next N frames" controls that used to sit above this, so they are gone here too.)
    val rendering by vm.rendering.collectAsState()
    BulkButton(
        localized("ui.render_updates"), StarColors.blue,
        help = localized("ui.render_updates_help"), enabled = info?.outliersLoaded == true && !rendering,
    ) { vm.renderCurrentFrame() }
}

/** The right panel's sections, each opened and closed from its header (macOS `RightPanelSectionKind`). */
enum class RightPanelSection { SELECTIVE_TOOLS, DISPLAY, PROCESSING, DEBUG }

/**
 * A section of the panel: its header, and [content] below it only while the section is open. The contents are laid out straight into
 * the panel's column, so they keep its spacing.
 */
@Composable
internal fun CollapsibleSection(vm: SequenceViewModel, section: RightPanelSection, title: String, help: String, content: @Composable () -> Unit) {
    val expanded by vm.expandedRightPanelSections.collectAsState()
    val open = section in expanded
    SectionHeader(title, help, open) { vm.toggleRightPanelSection(section) }
    if (open) content()
}

/** The labelled top of a section, with a chevron pointing right while it is closed and down while it is open; hovering it explains the section. */
@Composable
private fun SectionHeader(title: String, help: String, expanded: Boolean, onToggle: () -> Unit) {
    HoverTip(help) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(4.dp),
            modifier = Modifier.fillMaxWidth().clickable(onClick = onToggle).padding(top = 2.dp),
        ) {
            Text("›", color = StarColors.white, fontWeight = FontWeight.Bold, fontSize = 15.sp, modifier = Modifier.rotate(if (expanded) 90f else 0f))
            Text(title, color = StarColors.white, fontWeight = FontWeight.Bold, fontSize = 13.sp)
        }
    }
}

@Composable
private fun SectionDivider() {
    androidx.compose.material3.HorizontalDivider(color = StarColors.cellDefault, modifier = Modifier.padding(vertical = 4.dp))
}

/** A switch and its label, with hover help when [help] is given. */
@Composable
private fun SwitchRow(label: String, help: String?, checked: Boolean, onChange: (Boolean) -> Unit) {
    val row = @Composable {
        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
            androidx.compose.material3.Switch(checked = checked, onCheckedChange = onChange)
            Spacer(Modifier.width(6.dp))
            Text(label, color = StarColors.white, fontSize = 11.sp)
        }
    }
    if (help != null) HoverTip(help, row) else row()
}

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
                    .numberFieldRules(commit = { commit() }, revert = { text = count.toString() }),
            )
            Text(localized(suffixKey), color = color, fontSize = 11.sp)
        }
    }
}

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
                onValueChange = { maxText = it },
                singleLine = true,
                textStyle = androidx.compose.ui.text.TextStyle(color = if (valid) StarColors.white else StarColors.red, fontSize = 11.sp),
                cursorBrush = SolidColor(StarColors.white),
                modifier = Modifier
                    .width(40.dp)
                    .clip(RoundedCornerShape(3.dp))
                    .background(StarColors.cellDefault)
                    .padding(horizontal = 4.dp, vertical = 2.dp)
                    // Applied on Return or leaving the field, not on each key (the gui's rule): a number is not the user's answer until it is done.
                    .numberFieldRules(
                        commit = {
                            if (valid && parsed != null) { if (parsed != t.maxScale) t.setMaxScale(parsed, canvas) }
                            else maxText = formatScale(t.maxScale)
                        },
                        revert = { maxText = formatScale(t.maxScale) },
                    ),
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
private fun OpacitySlider(label: String, help: String, value: Float, onChange: (Float) -> Unit) {
    HoverTip(help) {
        Column {
            Text(label, color = StarColors.textPrimary, fontSize = 11.sp)
            androidx.compose.material3.Slider(value = value, onValueChange = onChange, valueRange = 0f..1f, modifier = Modifier.fillMaxWidth())
        }
    }
}

/** A scale for the Max field: "1", "2.5", not "1.0000". */
internal fun formatScale(v: Float): String = if (v == v.toInt().toFloat()) v.toInt().toString() else "%.2f".format(java.util.Locale.ROOT, v).trimEnd('0').trimEnd('.')
