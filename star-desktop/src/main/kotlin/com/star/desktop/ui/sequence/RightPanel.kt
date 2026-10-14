package com.star.desktop.ui.sequence

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.TooltipArea
import androidx.compose.foundation.TooltipPlacement
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Surface
import androidx.compose.ui.unit.DpOffset
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
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.star.desktop.domain.FastAdvancementType
import com.star.desktop.domain.ToolType
import com.star.desktop.domain.usesOutliers
import com.star.desktop.ui.components.toolPainter
import com.star.desktop.ui.sequence.edit.FrameTransform
import com.star.desktop.ui.theme.StarColors
import com.star.proto.CleanMethod
import com.star.desktop.i18n.localized

/**
 * Right panel (macOS `RightPanel`): the editing tool picker. Tool *paint* behavior is wired in
 * Phase 4 (outlier editing); this presents the 8 tools (shortcuts 1–8) with selection highlight.
 */
@Composable
fun RightPanel(vm: SequenceViewModel, modifier: Modifier = Modifier) {
    val tool by vm.tool.collectAsState()
    val current by vm.currentIndex.collectAsState()
    val fvm = androidx.compose.runtime.remember(current) { vm.frameVMFor(current) }
    val groups by fvm.groups.collectAsState()
    val decisions by fvm.decisions.collectAsState()
    val selected by fvm.selected.collectAsState()
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
        BulkButton(localized("ui.keep_all"), StarColors.green, help = localized("ui.keep_all_of_the_outlier_groups_in_the_frame")) { fvm.keepAll() }
        BulkButton(localized("ui.remove_all"), StarColors.red, help = localized("ui.remove_all_of_the_outlier_groups_in_the")) { fvm.removeAll() }
        BulkButton(localized("ui.clear_undecided"), StarColors.gray) { fvm.clearUndecided() }
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
        selected?.let { Text(localized("ui.selected_number", it), color = StarColors.orange, fontSize = 10.sp) }

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
        val refinementPending by vm.refinementPending.collectAsState()
        val busy by vm.isProcessing.collectAsState()
        BulkButton(
            localized("ui.re_run_horizon_refinement"), StarColors.orange,
            help = localized("ui.re_run_brightness_position_refinement_for"), enabled = refinementPending && !busy,
        ) { vm.runHorizonRefinement() }

        androidx.compose.material3.HorizontalDivider(color = StarColors.cellDefault, modifier = Modifier.padding(vertical = 4.dp))
        ZoomControls(vm)

        androidx.compose.material3.HorizontalDivider(color = StarColors.cellDefault, modifier = Modifier.padding(vertical = 4.dp))
        Text(localized("ui.clean_method"), color = StarColors.textPrimary, fontWeight = FontWeight.SemiBold, fontSize = 12.sp)
        val activeMethod = info?.cleanMethod ?: CleanMethod.CLEAN_SELECTIVE
        val cmLabels = CLEAN_METHODS.toMap()
        com.star.desktop.ui.components.VerticalStarPicker(
            options = CLEAN_METHODS.map { it.first },
            selected = activeMethod,
            label = { cmLabels[it] ?: "" },
            onSelect = { fvm.setCleanMethod(it) },
            modifier = Modifier.fillMaxWidth(),
        )

        androidx.compose.material3.HorizontalDivider(color = StarColors.cellDefault, modifier = Modifier.padding(vertical = 4.dp))
        Text(localized("ui.fast_skip_z_x"), color = StarColors.textPrimary, fontWeight = FontWeight.SemiBold, fontSize = 12.sp)
        val fastLabels = FAST_MODES.toMap()
        com.star.desktop.ui.components.VerticalStarPicker(
            options = FAST_MODES.map { it.first },
            selected = fastAdv,
            label = { fastLabels[it] ?: "" },
            onSelect = { vm.setFastAdvancement(it) },
            modifier = Modifier.fillMaxWidth(),
        )
      }
      com.star.desktop.ui.components.PanelChevron("»", { vm.setRightPanel(false) }, Modifier.padding(6.dp))
    }
}

/** Per-frame clean methods (proto `CleanMethod`) with display labels matching the macOS picker. */
private val CLEAN_METHODS: List<Pair<CleanMethod, String>> = listOf(
    CleanMethod.CLEAN_AUTOMATIC to "Automatic",
    CleanMethod.CLEAN_AUTOMATIC_TRUE to "Auto + Outliers",
    CleanMethod.CLEAN_SELECTIVE to "Selective",
)

/** Fast-skip strategies for the z/x transport keys (macOS `FastAdvancementType`). */
private val FAST_MODES: List<Pair<FastAdvancementType, String>> = listOf(
    FastAdvancementType.NORMAL to "Skip 20 frames",
    FastAdvancementType.SKIP_EMPTIES to "Skip empty frames",
    FastAdvancementType.TO_NEXT_POSITIVE to "Next w/ removals",
    FastAdvancementType.TO_NEXT_NEGATIVE to "Next w/ keeps",
    FastAdvancementType.TO_NEXT_UNKNOWN to "Next undecided",
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

/** Hover popup with a short help text, shown after the pointer rests on [content]. */
@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun HoverTip(text: String, content: @Composable () -> Unit) {
    TooltipArea(
        tooltip = {
            Surface(shape = RoundedCornerShape(4.dp), color = StarColors.prefsCard, shadowElevation = 4.dp) {
                Text(text, color = StarColors.white, fontSize = 11.sp, modifier = Modifier.widthIn(max = 260.dp).padding(8.dp))
            }
        },
        delayMillis = 400,
        tooltipPlacement = TooltipPlacement.CursorPoint(offset = DpOffset(0.dp, 16.dp)),
        content = content,
    )
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

/** A scale for the Max field: "1", "2.5", not "1.0000". */
internal fun formatScale(v: Float): String = if (v == v.toInt().toFloat()) v.toInt().toString() else "%.2f".format(java.util.Locale.ROOT, v).trimEnd('0').trimEnd('.')
