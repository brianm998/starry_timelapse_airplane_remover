package com.star.viewmodel

import androidx.compose.ui.graphics.ImageBitmap
import com.star.data.*
import com.star.proto.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*

/**
 * One frame: preview bitmap, label image, outlier group states, clean method.
 * Mirrors FrameViewModel.swift.
 */
class FrameViewModel(
    val sessionId: String,
    val frameIndex: Int,
    private val frameRepo: FrameRepository,
    private val outlierRepo: OutlierRepository,
    private val imageCache: ImageCache,
    parentScope: CoroutineScope,
) {
    val scope = CoroutineScope(Dispatchers.Default + SupervisorJob(parentScope.coroutineContext.job))

    private val _viewMode = MutableStateFlow(FrameViewMode.VIEW_ORIGINAL)
    val viewMode: StateFlow<FrameViewMode> = _viewMode.asStateFlow()

    private val _preview = MutableStateFlow<ImageBitmap?>(null)
    val preview: StateFlow<ImageBitmap?> = _preview.asStateFlow()

    private val _frameInfo = MutableStateFlow<FrameInfo?>(null)
    val frameInfo: StateFlow<FrameInfo?> = _frameInfo.asStateFlow()

    // Outlier groups (mutable so toggles can update decisions locally).
    private val _outlierGroups = MutableStateFlow<List<OutlierGroupState>>(emptyList())
    val outlierGroups: StateFlow<List<OutlierGroupState>> = _outlierGroups.asStateFlow()

    private val _labelImage = MutableStateFlow<LabelImage?>(null)
    val labelImage: StateFlow<LabelImage?> = _labelImage.asStateFlow()

    private val _loading = MutableStateFlow(false)
    val loading: StateFlow<Boolean> = _loading.asStateFlow()

    private val _error = MutableStateFlow<String?>(null)
    val error: StateFlow<String?> = _error.asStateFlow()

    // Preview path so we can invalidate cache on re-render.
    private var previewPath: String? = null

    fun load() {
        scope.launch {
            _loading.value = true
            try {
                val info = frameRepo.getInfo(sessionId, frameIndex)
                _frameInfo.value = info

                // supervisorScope: a failure in one child (e.g. outliers not ready) does not
                // cancel the other child (preview). Both exceptions surface via await().
                supervisorScope {
                    val previewDeferred = async { loadPreview(_viewMode.value) }
                    val groupsDeferred  = async { loadOutliers() }
                    // Await both; collect errors but don't let one hide the other.
                    var firstError: Throwable? = null
                    try { previewDeferred.await() } catch (e: Exception) { firstError = e }
                    try { groupsDeferred.await()  } catch (e: Exception) { if (firstError == null) firstError = e }
                    firstError?.let { throw it }
                }
            } catch (e: Exception) {
                _error.value = e.message
            } finally {
                _loading.value = false
            }
        }
    }

    private suspend fun loadPreview(mode: FrameViewMode) {
        val ref = frameRepo.getPreview(sessionId, frameIndex, mode)
        previewPath = ref.path
        _preview.value = imageCache.load(ref.path)
    }

    private suspend fun loadOutliers() {
        val groups = outlierRepo.getGroups(sessionId, frameIndex)
        _outlierGroups.value = groups.map { OutlierGroupState.from(it) }

        // Load label image for hit-testing.
        _labelImage.value = outlierRepo.getLabelImage(sessionId, frameIndex)
    }

    fun setViewMode(mode: FrameViewMode) {
        _viewMode.value = mode
        scope.launch { loadPreview(mode) }
    }

    /** Called when the user clicks on the outlier overlay at image-space coordinates. */
    fun hitTest(imageX: Int, imageY: Int, tool: ToolType): OutlierGroupState? {
        val label = _labelImage.value ?: return null
        val groupId = label.groupIdAt(imageX, imageY)
        if (groupId == 0) return null

        val group = _outlierGroups.value.firstOrNull { it.id == groupId } ?: return null
        val newDecision = when (tool) {
            ToolType.Remove, ToolType.Razor -> RemoveReason.RR_USER_REMOVE
            ToolType.Keep -> RemoveReason.RR_USER_KEEP
            else -> if (group.decision.willRemove == true) RemoveReason.RR_USER_KEEP else RemoveReason.RR_USER_REMOVE
        }

        // Update local state immediately for snappy UI.
        val updated = group.copy(decision = newDecision)
        _outlierGroups.value = _outlierGroups.value.map { if (it.id == groupId) updated else it }

        // Persist decision to stard (no rerender — fast toggle).
        scope.launch {
            val decision = OutlierDecision.newBuilder()
                .setGroupId(groupId.toLong().toInt())
                .setDecision(newDecision)
                .build()
            outlierRepo.setDecisions(sessionId, frameIndex, listOf(decision), rerender = false)
        }

        return updated
    }

    /** Request a rendered preview after decisions are finalized. */
    fun requestRerender() {
        scope.launch {
            val ref = outlierRepo.renderFrame(sessionId, frameIndex)
            previewPath?.let { imageCache.invalidate(it) }
            previewPath = ref.path
            _preview.value = imageCache.load(ref.path)
        }
    }

    fun setCleanMethod(method: CleanMethod) {
        scope.launch {
            val info = frameRepo.setCleanMethod(sessionId, frameIndex, method)
            _frameInfo.value = info
        }
    }

    fun keepAll() = bulkDecision(RemoveReason.RR_USER_KEEP)
    fun removeAll() = bulkDecision(RemoveReason.RR_USER_REMOVE)
    fun clearUndecided() {
        val decisions = _outlierGroups.value
            .filter { it.decision == RemoveReason.RR_UNDECIDED }
            .map { OutlierDecision.newBuilder().setGroupId(it.id).setDecision(RemoveReason.RR_UNDECIDED).build() }
        if (decisions.isEmpty()) return
        scope.launch { outlierRepo.setDecisions(sessionId, frameIndex, decisions) }
    }

    private fun bulkDecision(reason: RemoveReason) {
        val decisions = _outlierGroups.value.map { group ->
            OutlierDecision.newBuilder().setGroupId(group.id).setDecision(reason).build()
        }
        _outlierGroups.value = _outlierGroups.value.map { it.copy(decision = reason) }
        scope.launch { outlierRepo.setDecisions(sessionId, frameIndex, decisions) }
    }
}

/** Editing tool — maps to ToolType in ImageSequenceViewModel.swift. Tools 1–8 map to keyboard keys 1–8. */
enum class ToolType {
    Remove,         // 1 — remove_icon
    Keep,           // 2 — keep_icon
    Razor,          // 3 — razor_icon
    Shovel,         // 4 — shovel_icon
    Trash,          // 5 — add_to_trash_icon
    RemoveFromTrash,// 6 — remove_from_trash_icon
    Multi,          // 7 — multi_choice_icon
    Information,    // 8 — info_icon
    None,
}
