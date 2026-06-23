package com.star.desktop.ui.sequence

import androidx.compose.ui.graphics.ImageBitmap
import com.star.desktop.data.FrameRepository
import com.star.desktop.data.ImageCache
import com.star.desktop.data.OutlierRepository
import com.star.desktop.data.ProcessingRepository
import com.star.desktop.domain.InteractionMode
import com.star.desktop.domain.ToolType
import com.star.proto.FrameProcessingState
import com.star.proto.FrameViewMode
import com.star.proto.SessionInfo
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.launchIn
import kotlinx.coroutines.flow.onEach
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

/**
 * Per-session UI state (macOS `ImageSequenceViewModel`): interaction mode, current frame, selection,
 * tool, view mode, panel visibility, playback, plus the live processing state folded from the
 * progress stream. Preview loading auto-retries as processing makes a frame's preview available.
 */
class SequenceViewModel(
    private val scope: CoroutineScope,
    val info: SessionInfo,
    private val frames: FrameRepository,
    val processing: ProcessingRepository,
    val outliers: OutlierRepository,
    private val imageCache: ImageCache,
) {
    val sessionId: String = info.sessionId
    val frameCount: Int = info.frameCount

    // ---- interaction state ----
    private val _mode = MutableStateFlow(InteractionMode.SCRUB) // macOS default is scrub
    val mode: StateFlow<InteractionMode> = _mode.asStateFlow()

    private val _currentIndex = MutableStateFlow(0)
    val currentIndex: StateFlow<Int> = _currentIndex.asStateFlow()

    private val _selected = MutableStateFlow<Set<Int>>(emptySet())
    val selected: StateFlow<Set<Int>> = _selected.asStateFlow()

    private val _tool = MutableStateFlow(ToolType.REMOVE)
    val tool: StateFlow<ToolType> = _tool.asStateFlow()

    private val _viewMode = MutableStateFlow(FrameViewMode.VIEW_PROCESSED)
    val viewMode: StateFlow<FrameViewMode> = _viewMode.asStateFlow()

    private val _showFilmstrip = MutableStateFlow(true)
    val showFilmstrip: StateFlow<Boolean> = _showFilmstrip.asStateFlow()

    // ---- processing state (delegated) ----
    val frameStates: StateFlow<Map<Int, FrameProcessingState>> = processing.frameStates
    val isProcessing: StateFlow<Boolean> = processing.processing
    val sequenceState: StateFlow<String?> = processing.sequenceState

    // ---- current preview ----
    private val _currentPreview = MutableStateFlow<ImageBitmap?>(null)
    val currentPreview: StateFlow<ImageBitmap?> = _currentPreview.asStateFlow()
    private val _previewAvailable = MutableStateFlow(true)
    val previewAvailable: StateFlow<Boolean> = _previewAvailable.asStateFlow()

    // ---- playback ----
    private val _isPlaying = MutableStateFlow(false)
    val isPlaying: StateFlow<Boolean> = _isPlaying.asStateFlow()
    private val _playbackFps = MutableStateFlow(30)
    val playbackFps: StateFlow<Int> = _playbackFps.asStateFlow()
    private var playbackJob: Job? = null

    private var previewJob: Job? = null

    // Per-frame outlier-editing state, cached by frame index.
    private val frameVMs = mutableMapOf<Int, FrameViewModel>()

    /** Get (creating if needed) the [FrameViewModel] for [index]. */
    fun frameVMFor(index: Int): FrameViewModel =
        frameVMs.getOrPut(index) { FrameViewModel(scope, sessionId, index, outliers, frames) }

    /** The frame view model for the current index. */
    fun currentFrameVM(): FrameViewModel = frameVMFor(_currentIndex.value)

    init {
        // Subscribe to progress BEFORE any Processing.Start (the daemon attaches its continuation lazily).
        processing.subscribe(sessionId)

        // (Re)load the current preview whenever the index or view mode changes.
        combine(_currentIndex, _viewMode) { idx, mode -> idx to mode }
            .distinctUntilChanged()
            .onEach { (idx, mode) -> loadPreview(idx, mode) }
            .launchIn(scope)

        // As frames finish processing, a previously-missing preview may now exist — retry the current one.
        processing.frameStates
            .onEach { states ->
                if (!_previewAvailable.value) {
                    val idx = _currentIndex.value
                    if (states[idx] != null) loadPreview(idx, _viewMode.value)
                }
            }
            .launchIn(scope)
    }

    // ---- actions ----
    fun setMode(m: InteractionMode) { _mode.value = m }
    fun setViewMode(m: FrameViewMode) { _viewMode.value = m }
    fun setTool(t: ToolType) { _tool.value = t }
    fun toggleFilmstrip() { _showFilmstrip.value = !_showFilmstrip.value }

    fun setCurrentIndex(i: Int) {
        val clamped = i.coerceIn(0, (frameCount - 1).coerceAtLeast(0))
        _currentIndex.value = clamped
    }

    fun next() = setCurrentIndex(_currentIndex.value + 1)
    fun previous() = setCurrentIndex(_currentIndex.value - 1)

    fun select(index: Int, additive: Boolean = false, range: Boolean = false) {
        when {
            range -> {
                val lo = minOf(_currentIndex.value, index)
                val hi = maxOf(_currentIndex.value, index)
                _selected.value = (lo..hi).toSet()
            }
            additive -> _selected.value = _selected.value.toMutableSet().apply { if (!add(index)) remove(index) }
            else -> _selected.value = setOf(index)
        }
        setCurrentIndex(index)
    }

    fun processAll() = scope.launch { processing.start(sessionId, 0, -1) }
    fun processRemaining() = scope.launch { processing.start(sessionId, 0, -1) } // daemon resumes completed frames
    fun processCurrent() = scope.launch { processing.start(sessionId, _currentIndex.value, _currentIndex.value) }
    fun cancelProcessing() = scope.launch { processing.cancel(sessionId) }

    // ---- playback ----
    fun setPlaybackFps(fps: Int) { _playbackFps.value = fps.coerceIn(1, 90) }

    fun togglePlayback() = if (_isPlaying.value) stopPlayback() else startPlayback()

    fun startPlayback() {
        if (_isPlaying.value || frameCount <= 1) return
        _isPlaying.value = true
        _mode.value = InteractionMode.SCRUB // macOS forces scrub + black bg while playing
        playbackJob = scope.launch {
            while (isActive && _isPlaying.value) {
                val frameDelay = (1000L / _playbackFps.value).coerceAtLeast(11L)
                delay(frameDelay)
                val nextIdx = (_currentIndex.value + 1) % frameCount
                setCurrentIndex(nextIdx)
                prefetchAround(nextIdx)
            }
        }
    }

    fun stopPlayback() {
        _isPlaying.value = false
        playbackJob?.cancel()
        playbackJob = null
    }

    /** Preview path for [index] (for the filmstrip / grid to load). Null if not generated yet. */
    suspend fun previewRefPath(index: Int): String? =
        frames.previewPath(sessionId, index, FrameViewMode.VIEW_ORIGINAL)?.path

    suspend fun loadThumb(index: Int): ImageBitmap? =
        previewRefPath(index)?.let { imageCache.load(it) }

    fun close() {
        stopPlayback()
        processing.stop()
    }

    private suspend fun loadPreview(index: Int, mode: FrameViewMode) {
        previewJob?.cancel()
        previewJob = scope.launch {
            // Try requested mode; fall back to original if the processed preview isn't ready.
            val ref = frames.previewPath(sessionId, index, mode)
                ?: if (mode != FrameViewMode.VIEW_ORIGINAL) frames.previewPath(sessionId, index, FrameViewMode.VIEW_ORIGINAL) else null
            if (ref == null) {
                _previewAvailable.value = false
                _currentPreview.value = null
                return@launch
            }
            val bmp = imageCache.load(ref.path)
            if (_currentIndex.value == index) {
                _currentPreview.value = bmp
                _previewAvailable.value = bmp != null
            }
        }
    }

    private fun prefetchAround(index: Int) {
        scope.launch {
            for (i in (index + 1)..(index + 3)) {
                if (i < frameCount) previewRefPath(i)?.let { imageCache.load(it) }
            }
        }
    }
}
