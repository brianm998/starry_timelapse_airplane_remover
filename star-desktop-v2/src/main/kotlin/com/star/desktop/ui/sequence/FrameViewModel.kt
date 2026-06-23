package com.star.desktop.ui.sequence

import com.star.desktop.data.FrameRepository
import com.star.desktop.data.OutlierRepository
import com.star.desktop.domain.OutlierDecisions
import com.star.desktop.domain.ToolType
import com.star.proto.CleanMethod
import com.star.proto.FrameInfo
import com.star.proto.OutlierDecision
import com.star.proto.OutlierGroup
import com.star.proto.RemoveReason
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

/**
 * State for one frame's outlier editing (macOS `FrameViewModel` + `OutlierGroupViewModel`): the
 * group list, a local decision overlay (so toggles tint instantly), the 16-bit label map for
 * click hit-testing, and the selected group. Decisions are persisted via `Outlier.SetDecisions`.
 *
 * Group ids are proto `uint32` carried as `Int` — compared by equality, never narrowed.
 */
class FrameViewModel(
    private val scope: CoroutineScope,
    val sessionId: String,
    val frameIndex: Int,
    private val outliers: OutlierRepository,
    private val frames: FrameRepository,
) {
    private val _groups = MutableStateFlow<List<OutlierGroup>>(emptyList())
    val groups: StateFlow<List<OutlierGroup>> = _groups.asStateFlow()

    /** groupId → current decision (local overlay, seeded from the server `should_remove`). */
    private val _decisions = MutableStateFlow<Map<Int, RemoveReason>>(emptyMap())
    val decisions: StateFlow<Map<Int, RemoveReason>> = _decisions.asStateFlow()

    private val _labelMap = MutableStateFlow<OutlierRepository.LabelMap?>(null)
    val labelMap: StateFlow<OutlierRepository.LabelMap?> = _labelMap.asStateFlow()

    private val _selected = MutableStateFlow<Int?>(null)
    val selected: StateFlow<Int?> = _selected.asStateFlow()

    /** groupId currently under the pointer (macOS `arrowSelected`); single-valued, like the macOS hover. */
    private val _hovered = MutableStateFlow<Int?>(null)
    val hovered: StateFlow<Int?> = _hovered.asStateFlow()
    fun hover(groupId: Int?) { _hovered.value = groupId }

    /** Per-frame info (status, outlier counts, clean method) from `Frame.Get`. */
    private val _info = MutableStateFlow<FrameInfo?>(null)
    val info: StateFlow<FrameInfo?> = _info.asStateFlow()

    private val _loading = MutableStateFlow(false)
    val loading: StateFlow<Boolean> = _loading.asStateFlow()

    private var loaded = false

    /** Load groups + label map. Idempotent; safe to call when entering the frame. */
    fun load(force: Boolean = false) {
        if (loaded && !force) return
        loaded = true
        scope.launch {
            _loading.value = true
            try {
                runCatching { _info.value = frames.info(sessionId, frameIndex) }
                val gs = outliers.list(sessionId, frameIndex)
                _groups.value = gs
                _decisions.value = gs.associate { it.id to it.shouldRemove }
                val ref = frames.labelImage(sessionId, frameIndex)
                _labelMap.value = ref?.let { outliers.loadLabelMap(it.path) }
            } finally {
                _loading.value = false
            }
        }
    }

    fun decisionFor(groupId: Int): RemoveReason = _decisions.value[groupId] ?: RemoveReason.RR_UNDECIDED

    fun selectGroup(groupId: Int?) { _selected.value = groupId }

    /** Override this frame's clean method (`Frame.SetCleanMethod`); the daemon returns updated info. */
    fun setCleanMethod(method: CleanMethod) {
        if (_info.value?.cleanMethod == method) return
        scope.launch {
            runCatching { frames.setCleanMethod(sessionId, frameIndex, method) }
                .onSuccess { _info.value = it }
        }
    }

    /**
     * Apply the active [tool] to the clicked group (single-group tap path; macOS `OutlierGroupView.onTapGesture`).
     * TRASH dumps the tapped group into the trash (via the area tool over the group's own bounds, which
     * `contains` it). Razor/shovel/get-from-trash have no single-group action in macOS — they toggle the
     * tapped group's decision, matching the macOS `toggleRemoveReason` fallback. The real razor/shovel/trash/
     * extract behavior is the rubber-band drag (see [applyAreaTool]).
     */
    fun applyTool(groupId: Int, tool: ToolType) {
        when (tool) {
            ToolType.REMOVE -> setDecision(groupId, RemoveReason.RR_USER_REMOVE)
            ToolType.KEEP -> setDecision(groupId, RemoveReason.RR_USER_KEEP)
            ToolType.INFORMATION -> selectGroup(groupId)
            ToolType.TRASH -> {
                val g = _groups.value.firstOrNull { it.id == groupId } ?: return
                // Dump EXACTLY the tapped group by id (macOS dumpInTrash(_:)); the rect is ignored when groupId > 0.
                applyAreaTool(tool, g.bounds.minX.toFloat(), g.bounds.minY.toFloat(), g.bounds.maxX.toFloat(), g.bounds.maxY.toFloat(), groupId)
            }
            else -> toggle(groupId)
        }
    }

    /** Map an area-drag editing tool to its daemon [com.star.proto.OutlierAreaTool] (null for MULTI / non-area tools). */
    private fun ToolType.toAreaTool(): com.star.proto.OutlierAreaTool? = when (this) {
        ToolType.RAZOR -> com.star.proto.OutlierAreaTool.AREA_TOOL_RAZOR
        ToolType.SHOVEL -> com.star.proto.OutlierAreaTool.AREA_TOOL_SHOVEL
        ToolType.TRASH -> com.star.proto.OutlierAreaTool.AREA_TOOL_TRASH
        ToolType.REMOVE_FROM_TRASH -> com.star.proto.OutlierAreaTool.AREA_TOOL_EXTRACT_TRASH
        else -> null
    }

    /**
     * Apply an area editing tool (razor/shovel/trash/get-from-trash) to the drag rectangle (image px),
     * then refresh this frame's groups so the overlay reflects the new membership. [groupId] > 0 is
     * TRASH-only (single-tap): dump exactly that group, ignoring the rectangle.
     */
    fun applyAreaTool(tool: ToolType, startX: Float, startY: Float, endX: Float, endY: Float, groupId: Int = 0) {
        val areaTool = tool.toAreaTool() ?: return
        scope.launch {
            runCatching { outliers.applyAreaTool(sessionId, frameIndex, areaTool, startX, startY, endX, endY, groupId = groupId) }
            load(force = true)
        }
    }

    /** Re-run the decision-tree classifier on this frame, then refresh the decisions from the daemon. */
    fun applyDecisionTree(overwrite: Boolean = true) {
        scope.launch {
            runCatching { outliers.applyDecisionTree(sessionId, frameIndex, overwrite) }
                .onSuccess { load(force = true) }
        }
    }

    fun toggle(groupId: Int) = setDecision(groupId, OutlierDecisions.toggled(decisionFor(groupId)))

    fun setDecision(groupId: Int, reason: RemoveReason) = apply(listOf(groupId to reason))

    fun keepAll() = apply(_groups.value.map { it.id to RemoveReason.RR_USER_KEEP })
    fun removeAll() = apply(_groups.value.map { it.id to RemoveReason.RR_USER_REMOVE })
    fun clearUndecided() =
        apply(_groups.value.filter { !OutlierDecisions.isDecided(decisionFor(it.id)) }.map { it.id to RemoveReason.RR_UNDECIDED })

    private fun apply(changes: List<Pair<Int, RemoveReason>>) {
        if (changes.isEmpty()) return
        _decisions.update { it + changes } // optimistic local tint
        scope.launch {
            val protoDecisions = changes.map {
                OutlierDecision.newBuilder().setGroupId(it.first).setDecision(it.second).build()
            }
            runCatching { outliers.setDecisions(sessionId, frameIndex, protoDecisions, rerender = false) }
        }
    }
}
