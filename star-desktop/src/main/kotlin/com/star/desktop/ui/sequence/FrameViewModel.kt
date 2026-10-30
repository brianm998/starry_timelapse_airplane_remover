package com.star.desktop.ui.sequence

import com.star.desktop.data.FrameRepository
import com.star.desktop.data.OutlierRepository
import com.star.desktop.domain.OutlierDecisions
import com.star.desktop.i18n.localized
import com.star.desktop.domain.ToolType
import com.star.proto.CleanMethod
import com.star.proto.FrameInfo
import com.star.proto.OutlierDecision
import com.star.proto.OutlierGroup
import com.star.proto.RemoveReason
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlin.math.roundToInt

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
    /** Shows a failed user action to the user (macOS `report(error:)`). */
    private val onError: (String) -> Unit = {},
) {
    private val _groups = MutableStateFlow<List<OutlierGroup>>(emptyList())
    val groups: StateFlow<List<OutlierGroup>> = _groups.asStateFlow()

    /** groupId → current decision (local overlay, seeded from the server `should_remove`). */
    private val _decisions = MutableStateFlow<Map<Int, RemoveReason>>(emptyMap())
    val decisions: StateFlow<Map<Int, RemoveReason>> = _decisions.asStateFlow()

    private val _labelMap = MutableStateFlow<OutlierRepository.LabelMap?>(null)
    val labelMap: StateFlow<OutlierRepository.LabelMap?> = _labelMap.asStateFlow()

    /**
     * The groups selected for the details view (macOS `isSelected`): drawn in orange on the frame, and the rows selected in the outlier
     * window. Set by an Information click and by selecting rows in the window.
     */
    private val _selection = MutableStateFlow<Set<Int>>(emptySet())
    val selection: StateFlow<Set<Int>> = _selection.asStateFlow()

    /** groupId currently under the pointer (macOS `arrowSelected`); single-valued, like the macOS hover. */
    private val _hovered = MutableStateFlow<Int?>(null)
    val hovered: StateFlow<Int?> = _hovered.asStateFlow()
    fun hover(groupId: Int?) { _hovered.value = groupId }

    /** Per-frame info (status, outlier counts, clean method) from `Frame.Get`. */
    private val _info = MutableStateFlow<FrameInfo?>(null)
    val info: StateFlow<FrameInfo?> = _info.asStateFlow()

    private val _loading = MutableStateFlow(false)
    val loading: StateFlow<Boolean> = _loading.asStateFlow()

    /** Whether the frame's trash is being read (the status line says so, as macOS's "loading outlier trash views"). */
    private val _loadingTrash = MutableStateFlow(false)
    val loadingTrash: StateFlow<Boolean> = _loadingTrash.asStateFlow()

    private var loaded = false
    private var loadJob: Job? = null

    /**
     * Load groups + label map; a no-op once loaded unless [force]d. A second load started while one is
     * running replaces it. Returns the load in flight (null if there was nothing to do).
     */
    fun load(force: Boolean = false): Job? {
        if (loaded && !force) return loadJob
        loaded = true
        loadJob?.cancel()
        val job = scope.launch {
            val me = coroutineContext[Job]
            _loading.value = true
            try {
                runCatching { _info.value = frames.info(sessionId, frameIndex) }
                val gs = outliers.list(sessionId, frameIndex)
                _groups.value = gs
                _decisions.value = gs.associate { it.id to it.shouldRemove }
                val ref = frames.labelImage(sessionId, frameIndex)
                _labelMap.value = ref?.let { outliers.loadLabelMap(it.path) }
            } finally {
                if (loadJob === me) _loading.value = false
            }
        }
        loadJob = job
        return job
    }

    /**
     * What was loaded is out of date (the frame was processed, edited elsewhere, or its outliers
     * loaded): the next [ensureLoaded] fetches it again. The caller reloads right away for a frame
     * that is on screen.
     */
    fun invalidate() { loaded = false }

    /**
     * Let go of the hit-testing label map (tens of MB per frame at full resolution) once this frame is far from
     * the one being looked at. The next [load] fetches everything again, so this also marks it not loaded.
     */
    fun releaseLabels() {
        loadJob?.cancel()
        loaded = false
        _labelMap.value = null
    }

    /** Return once the groups are loaded, loading them if need be: for callers that must not act on an empty list. */
    suspend fun ensureLoaded() {
        load()?.join()
    }

    /** Take the counts the daemon returned with a change to this frame. */
    fun applyInfo(info: FrameInfo) { _info.value = info }

    /**
     * The group under image pixel ([x], [y]), or 0 for none: the group whose pixel it is, else the smallest group whose bounding box
     * contains it (macOS hits anywhere in a group's box, smaller boxes on top). Only groups that are separate things in the UI count:
     * one of 40 pixels or fewer is drawn in a combined mask with the other small ones and cannot be hovered or clicked.
     */
    fun groupAt(x: Int, y: Int): Int {
        val large = _groups.value.filter(com.star.desktop.ui.sequence.edit.OutlierOverlay::isLarge)
        val exact = _labelMap.value?.idAt(x, y) ?: 0
        if (exact > 0 && large.any { it.id == exact }) return exact
        return com.star.desktop.domain.OutlierHit.smallestBoxContaining(large, x, y)?.id ?: 0
    }

    /**
     * The group whose edge arrow is under image point ([x], [y]), or 0: the arrows at the frame's edges are clickable and toggle the
     * group, but only the ones showing (those of a hovered, selected, undecided or to-be-removed group).
     */
    fun arrowGroupAt(x: Float, y: Float, frameWidth: Float, frameHeight: Float): Int {
        val arrowLength = frameWidth / SequenceViewModel.ARROW_LENGTH_DIVISOR
        val arrowHeight = frameWidth / SequenceViewModel.ARROW_HEIGHT_DIVISOR
        return com.star.desktop.domain.OutlierHit.arrowGroupAt(
            _groups.value.filter(com.star.desktop.ui.sequence.edit.OutlierOverlay::isLarge),
            x, y, frameWidth, frameHeight, arrowLength, arrowHeight,
        ) { g ->
            val willRemove = OutlierDecisions.willRemove(_decisions.value[g.id] ?: g.shouldRemove)
            g.id == _hovered.value || g.id in _selection.value || willRemove != false
        }?.id ?: 0
    }

    /** What a pointer at image point ([x], [y]) means: a group's pixels or box, else one of the arrows; 0 for neither. */
    fun hitAt(x: Float, y: Float, frameWidth: Float, frameHeight: Float): Int {
        val g = groupAt(x.roundToInt(), y.roundToInt())
        return if (g > 0) g else arrowGroupAt(x, y, frameWidth, frameHeight)
    }

    /** The frame's trash as a mask the view draws in yellow while the trash is shown, or null if there is none to draw. */
    suspend fun loadTrashMask(): OutlierRepository.Mask? {
        _loadingTrash.value = true
        try {
            val ref = frames.trashImage(sessionId, frameIndex) ?: return null
            return outliers.loadMask(ref.path)
        } finally {
            _loadingTrash.value = false
        }
    }

    fun decisionFor(groupId: Int): RemoveReason = _decisions.value[groupId] ?: RemoveReason.RR_UNDECIDED

    /** The daemon changed one group (its line); take it in place, without loading the frame again. */
    fun groupChanged(group: OutlierGroup) {
        _groups.update { list -> list.map { if (it.id == group.id) group else it } }
    }

    fun selectGroups(groupIds: Set<Int>) { _selection.value = groupIds }

    fun selectGroup(groupId: Int?) { _selection.value = groupId?.let { setOf(it) } ?: emptySet() }

    /** Override this frame's clean method (`Frame.SetCleanMethod`); the daemon returns updated info. */
    fun setCleanMethod(method: CleanMethod) {
        if (_info.value?.cleanMethod == method) return
        scope.launch {
            runCatching { frames.setCleanMethod(sessionId, frameIndex, method) }
                .onSuccess { _info.value = it }
                .onFailure { reportFailure(it) }
        }
    }

    /**
     * Apply the active [tool] to the clicked group (single-group tap path; macOS `OutlierGroupView.onTapGesture`).
     * TRASH dumps the tapped group into the trash (via the area tool over the group's own bounds, which
     * `contains` it). Every other tool toggles the tapped group's decision, matching the macOS
     * `toggleRemoveReason`: a click on a group Remove has already removed keeps it, and one on an undecided group removes it.
     * What Remove and Keep set is what dragging a box does ([setDecisionsInBox]). The real razor/shovel/trash/
     * extract behavior is the rubber-band drag (see [applyAreaTool]).
     */
    fun applyTool(groupId: Int, tool: ToolType) {
        when (tool) {
            ToolType.INFORMATION -> selectGroup(groupId)
            ToolType.TRASH -> {
                val g = _groups.value.firstOrNull { it.id == groupId } ?: return
                // Dump EXACTLY the tapped group by id (macOS dumpInTrash(_:)); the rect is ignored when groupId > 0.
                applyAreaTool(tool, g.bounds.minX.toFloat(), g.bounds.minY.toFloat(), g.bounds.maxX.toFloat(), g.bounds.maxY.toFloat(), groupId)
            }
            else -> setDecision(groupId, OutlierDecisions.clicked(decisionFor(groupId), tool))
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
    fun applyAreaTool(tool: ToolType, startX: Float, startY: Float, endX: Float, endY: Float, groupId: Int = 0, includingTrash: Boolean = false) {
        val areaTool = tool.toAreaTool() ?: return
        scope.launch {
            runCatching { outliers.applyAreaTool(sessionId, frameIndex, areaTool, startX, startY, endX, endY, includingTrash = includingTrash, groupId = groupId) }
                .onFailure { reportFailure(it) }
            load(force = true)
        }
    }

    /**
     * Remove / Keep dragged over a box (macOS `userSelectAllOutliers(between:)`): every group whose whole bounding box is inside
     * it is set, and the frame is read again. The daemon queues the frame to be saved like any other edit.
     */
    fun setDecisionsInBox(shouldRemove: Boolean, startX: Float, startY: Float, endX: Float, endY: Float, includingTrash: Boolean = false) {
        scope.launch {
            runCatching {
                outliers.setDecisionsInArea(sessionId, frameIndex, frameIndex, shouldRemove, startX, startY, endX, endY, includingTrash = includingTrash)
            }
                .onSuccess { r -> r.framesList.firstOrNull()?.let(::applyInfo) }
                .onFailure { reportFailure(it) }
            load(force = true)
        }
    }

    /** The groups an Information drag over a box lists: those wholly inside it, largest first. */
    fun groupsInBox(startX: Float, startY: Float, endX: Float, endY: Float): List<OutlierGroup> =
        com.star.desktop.domain.groupsInsideBox(_groups.value, startX, startY, endX, endY)

    /**
     * Run the decision-tree classifier over this frame's outliers (macOS "Decision Tree All" / "DT Auto Only"),
     * then render the frame, so the picture follows the decisions, and refresh what is shown.
     *
     * [overwrite] false keeps every decision already made, the user's included: the classifier only fills in
     * groups nobody has decided about. [autoOnly] limits it to the automatically selected groups.
     */
    fun applyDecisionTree(
        overwrite: Boolean,
        autoOnly: Boolean = false,
        minimumSize: Int = 0,
        includingTrash: Boolean = false,
    ) {
        scope.launch {
            runCatching {
                outliers.applyDecisionTree(
                    sessionId, frameIndex, overwrite,
                    autoOnly = autoOnly, includingTrash = includingTrash, minimumSize = minimumSize, rerender = true,
                )
            }
                .onSuccess { _info.value = it.frame; load(force = true) }
                .onFailure { reportFailure(it) { localized("ui.decision_tree_render_failed", it.message ?: it) } }
        }
    }

    fun toggle(groupId: Int) = setDecision(groupId, OutlierDecisions.toggled(decisionFor(groupId)))

    fun setDecision(groupId: Int, reason: RemoveReason) = apply(listOf(groupId to reason))

    /**
     * Keep All / Remove All / Clear Undecided (macOS `userSelectAllOutliers` / `userSelectUndecidedOutliers`): done by the daemon
     * over the frame's groups, which works whether or not this client has loaded them (from the menu or keys in scrub or grid mode it has
     * not), and over the trash as well when [includingTrash]. Clear Undecided keeps the undecided groups.
     */
    private fun setAll(shouldRemove: Boolean, undecidedOnly: Boolean, includingTrash: Boolean) {
        scope.launch {
            runCatching { outliers.setAll(sessionId, frameIndex, shouldRemove, undecidedOnly, includingTrash) }
                .onSuccess { applyInfo(it.frame) }
                .onFailure { reportFailure(it) }
            load(force = true)
        }
    }

    fun keepAll(includingTrash: Boolean = false) = setAll(shouldRemove = false, undecidedOnly = false, includingTrash = includingTrash)
    fun removeAll(includingTrash: Boolean = false) = setAll(shouldRemove = true, undecidedOnly = false, includingTrash = includingTrash)
    fun clearUndecided(includingTrash: Boolean = false) = setAll(shouldRemove = false, undecidedOnly = true, includingTrash = includingTrash)

    private fun apply(changes: List<Pair<Int, RemoveReason>>) {
        if (changes.isEmpty()) return
        _decisions.update { it + changes } // optimistic local tint
        scope.launch {
            val protoDecisions = changes.map {
                OutlierDecision.newBuilder().setGroupId(it.first).setDecision(it.second).build()
            }
            runCatching { outliers.setDecisions(sessionId, frameIndex, protoDecisions, rerender = false) }
                .onSuccess { _info.value = it.frame }
                .onFailure {
                    // The optimistic tint above is now wrong; show what the daemon actually has.
                    reportFailure(it)
                    load(force = true)
                }
        }
    }

    /** Tell the user an action on this frame failed; cancellation is not a failure. */
    private fun reportFailure(e: Throwable, message: () -> String = { localized("ui.error_processing_frame", frameIndex, e.message ?: e) }) {
        if (e is kotlinx.coroutines.CancellationException) return
        onError(message())
    }
}
