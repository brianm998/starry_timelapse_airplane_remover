package com.star.desktop.ui.sequence

import androidx.compose.ui.graphics.ImageBitmap
import com.star.desktop.data.ExportRepository
import com.star.desktop.data.FrameRepository
import com.star.desktop.data.ImageCache
import com.star.desktop.data.OutlierRepository
import com.star.desktop.data.ProcessingRepository
import com.star.desktop.domain.FastAdvancementType
import com.star.desktop.domain.InteractionMode
import com.star.desktop.domain.ToolType
import com.star.desktop.domain.VideoPlayMode
import com.star.desktop.util.Log
import com.star.proto.FrameProcessingState
import com.star.proto.FrameViewMode
import com.star.proto.ProgressEvent
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
    private val export: ExportRepository,
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

    // Grid thumbnail size (macOS gridThumbnailScale): a fraction of the full image width, 0.02..0.5.
    private val _gridThumbnailScale = MutableStateFlow(0.12f)
    val gridThumbnailScale: StateFlow<Float> = _gridThumbnailScale.asStateFlow()
    fun setGridThumbnailScale(v: Float) { _gridThumbnailScale.value = v.coerceIn(0.02f, 0.5f) }

    private val _leftPanelShowing = MutableStateFlow(true)
    val leftPanelShowing: StateFlow<Boolean> = _leftPanelShowing.asStateFlow()
    private val _rightPanelShowing = MutableStateFlow(true)
    val rightPanelShowing: StateFlow<Boolean> = _rightPanelShowing.asStateFlow()
    fun setLeftPanel(showing: Boolean) { _leftPanelShowing.value = showing }
    fun setRightPanel(showing: Boolean) { _rightPanelShowing.value = showing }
    /** macOS `toggleSidePanels` (Tab): both shown → both hide; otherwise → both show. */
    fun toggleSidePanels() {
        val hide = _leftPanelShowing.value && _rightPanelShowing.value
        _leftPanelShowing.value = !hide
        _rightPanelShowing.value = !hide
    }

    // Edit sub-mode: when on, the center view is the horizon painter instead of the outlier overlay.
    private val _horizonPaintMode = MutableStateFlow(false)
    val horizonPaintMode: StateFlow<Boolean> = _horizonPaintMode.asStateFlow()
    fun toggleHorizonPaint() { _horizonPaintMode.value = !_horizonPaintMode.value }

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
    private val _playbackFps = MutableStateFlow(30) // macOS videoPlaybackFramerate (distinct from export fps)
    val playbackFps: StateFlow<Int> = _playbackFps.asStateFlow()
    private val _playMode = MutableStateFlow(VideoPlayMode.FORWARD)
    val playMode: StateFlow<VideoPlayMode> = _playMode.asStateFlow()
    private val _fastAdvancement = MutableStateFlow(FastAdvancementType.NORMAL)
    val fastAdvancement: StateFlow<FastAdvancementType> = _fastAdvancement.asStateFlow()
    fun setFastAdvancement(t: FastAdvancementType) { _fastAdvancement.value = t }
    private var playbackJob: Job? = null

    // ---- render (Outlier.RenderFrame / Export.RenderSequence) ----
    private val _rendering = MutableStateFlow(false)
    val rendering: StateFlow<Boolean> = _rendering.asStateFlow()
    private val _renderProgress = MutableStateFlow<Float?>(null) // null = current-frame (indeterminate)
    val renderProgress: StateFlow<Float?> = _renderProgress.asStateFlow()

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

    /**
     * Selection (macOS GridView): shift = range from the anchor (currentIndex stays put);
     * cmd/ctrl = additive toggle but the anchor is never deselected; plain = single + move anchor.
     */
    fun select(index: Int, additive: Boolean = false, range: Boolean = false) {
        when {
            range -> {
                val lo = minOf(_currentIndex.value, index)
                val hi = maxOf(_currentIndex.value, index)
                _selected.value = (lo..hi).toSet() // anchor stays
            }
            additive -> {
                val cur = _currentIndex.value
                _selected.value = _selected.value.toMutableSet().apply {
                    if (index in this) { if (index != cur) remove(index) } else { add(index); add(cur) }
                } // anchor stays
            }
            else -> { _selected.value = setOf(index); setCurrentIndex(index) }
        }
    }

    fun processAll() = scope.launch { processing.start(sessionId, 0, -1) }
    fun processRemaining() = scope.launch { processing.start(sessionId, 0, -1) } // daemon resumes completed frames
    fun processCurrent() = scope.launch { processing.start(sessionId, _currentIndex.value, _currentIndex.value) }
    fun cancelProcessing() = scope.launch { processing.cancel(sessionId) }

    // ---- render ----
    /** Paint the current frame with its decisions (`Outlier.RenderFrame`) and show the result. */
    fun renderCurrentFrame() = scope.launch {
        if (_rendering.value || isProcessing.value) return@launch
        val idx = _currentIndex.value
        _rendering.value = true
        _renderProgress.value = null // indeterminate: a single frame
        try {
            val ref = outliers.renderFrame(sessionId, idx)
            imageCache.invalidate(ref.path) // daemon overwrites the same path — drop the stale bitmap
            val bmp = imageCache.load(ref.path)
            if (_currentIndex.value == idx && bmp != null) {
                _currentPreview.value = bmp
                _previewAvailable.value = true
            }
        } catch (e: Throwable) {
            Log.w("Sequence") { "render current frame failed: ${e.message}" }
        } finally {
            _rendering.value = false
        }
    }

    /**
     * Render every frame's final output (`Export.RenderSequence`). The daemon shares one progress slot
     * per session with the processing stream, so we drop that subscription for the duration and restore
     * it afterward (mirrors the Render Video dialog).
     */
    fun renderAllFrames() = scope.launch {
        if (_rendering.value || isProcessing.value) return@launch
        _rendering.value = true
        _renderProgress.value = 0f
        processing.stop() // free the shared progress slot
        try {
            export.renderSequence(sessionId).collect { ev ->
                if (ev.kindCase == ProgressEvent.KindCase.IO_PROGRESS) {
                    val io = ev.ioProgress
                    _renderProgress.value = if (io.total > 0) io.current.toFloat() / io.total else null
                }
            }
            imageCache.clear() // every output frame changed; reload the visible one fresh
            loadPreview(_currentIndex.value, _viewMode.value)
        } catch (e: Throwable) {
            Log.w("Sequence") { "render all frames failed: ${e.message}" }
        } finally {
            _renderProgress.value = null
            _rendering.value = false
            processing.subscribe(sessionId) // restore live progress
        }
    }

    // ---- transport ----
    fun goToFirst() = setCurrentIndex(0)
    fun goToLast() = setCurrentIndex(frameCount - 1)
    fun fastForward() = fastSkip(forward = true)
    fun fastPrevious() = fastSkip(forward = false)

    /**
     * Fast-skip per the active [FastAdvancementType]: NORMAL jumps [FAST_SKIP_AMOUNT] frames;
     * the category modes scan frame-by-frame (via `Frame.Get` counts) to the next non-empty frame,
     * stopping at the sequence boundary (macOS `transition(until:)`).
     */
    private fun fastSkip(forward: Boolean) {
        val mode = _fastAdvancement.value
        if (mode == FastAdvancementType.NORMAL) {
            setCurrentIndex(_currentIndex.value + if (forward) FAST_SKIP_AMOUNT else -FAST_SKIP_AMOUNT)
            return
        }
        scope.launch {
            var i = _currentIndex.value
            while (true) {
                val next = i + if (forward) 1 else -1
                if (next < 0 || next >= frameCount) { if (i != _currentIndex.value) setCurrentIndex(i); break }
                val c = runCatching { frames.info(sessionId, next) }.getOrNull()
                val skip = c != null && when (mode) {
                    FastAdvancementType.SKIP_EMPTIES ->
                        (c.numPositiveOutliers + c.numNegativeOutliers + c.numUndecidedOutliers) == 0
                    FastAdvancementType.TO_NEXT_POSITIVE -> c.numPositiveOutliers == 0
                    FastAdvancementType.TO_NEXT_NEGATIVE -> c.numNegativeOutliers == 0
                    FastAdvancementType.TO_NEXT_UNKNOWN -> c.numUndecidedOutliers == 0
                    else -> false
                }
                if (skip) i = next else { setCurrentIndex(next); break }
            }
        }
    }

    // ---- playback ----
    fun setPlaybackFps(fps: Int) { _playbackFps.value = fps.coerceIn(1, 90) }

    fun togglePlayback() = if (_isPlaying.value) stopPlayback() else startPlayback()
    fun playForward() { _playMode.value = VideoPlayMode.FORWARD; togglePlayback() }
    fun playReverse() { _playMode.value = VideoPlayMode.REVERSE; togglePlayback() }

    fun startPlayback() {
        if (_isPlaying.value || frameCount <= 1) return
        _isPlaying.value = true
        _mode.value = InteractionMode.SCRUB // macOS forces scrub + black bg while playing
        val step = if (_playMode.value == VideoPlayMode.REVERSE) -1 else 1
        playbackJob = scope.launch {
            while (isActive && _isPlaying.value) {
                val frameDelay = (1000L / _playbackFps.value).coerceAtLeast(11L)
                delay(frameDelay)
                val next = _currentIndex.value + step
                if (next < 0 || next >= frameCount) {        // stop at the boundary; no wrap
                    setCurrentIndex(if (next < 0) 0 else frameCount - 1)
                    _isPlaying.value = false
                    break
                }
                setCurrentIndex(next)
                prefetchAround(next, step)
            }
        }
    }

    fun stopPlayback() {
        _isPlaying.value = false
        playbackJob?.cancel()
        playbackJob = null
    }

    /** Preview path for [index] in [mode], falling back through the other view modes. Null if none exist. */
    suspend fun previewRefPath(index: Int, mode: FrameViewMode = FrameViewMode.VIEW_ORIGINAL): String? {
        for (m in (listOf(mode) + PREVIEW_FALLBACK).distinct()) {
            frames.previewPath(sessionId, index, m)?.let { return it.path }
        }
        return null
    }

    suspend fun loadThumb(index: Int, mode: FrameViewMode = FrameViewMode.VIEW_ORIGINAL): ImageBitmap? =
        previewRefPath(index, mode)?.let { imageCache.load(it) }

    /** Per-frame status/counts/clean-method for the grid header & right panel (`Frame.Get`). */
    suspend fun frameInfo(index: Int): com.star.proto.FrameInfo? =
        runCatching { frames.info(sessionId, index) }.getOrNull()

    fun close() {
        stopPlayback()
        processing.stop()
    }

    private suspend fun loadPreview(index: Int, mode: FrameViewMode) {
        previewJob?.cancel()
        previewJob = scope.launch {
            // Try the requested mode, then fall back through the others — which preview types the
            // daemon actually wrote depends on the clean method (e.g. selective writes a subtraction
            // preview but no auto-processed/original preview), so we show whatever exists.
            val order = (listOf(mode) + PREVIEW_FALLBACK).distinct()
            var ref: com.star.proto.ImageRef? = null
            for (m in order) {
                ref = frames.previewPath(sessionId, index, m)
                if (ref != null) break
            }
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

    private companion object {
        const val FAST_SKIP_AMOUNT = 20 // macOS fastSkipAmount

        val PREVIEW_FALLBACK = listOf(
            FrameViewMode.VIEW_PROCESSED,
            FrameViewMode.VIEW_SUBTRACTION,
            FrameViewMode.VIEW_ORIGINAL,
            FrameViewMode.VIEW_VALIDATION,
        )
    }

    /** Prefetch the next few frames in the play [direction] (+1 forward, -1 reverse). */
    private fun prefetchAround(index: Int, direction: Int = 1) {
        scope.launch {
            for (n in 1..3) {
                val i = index + direction * n
                if (i in 0 until frameCount) previewRefPath(i)?.let { imageCache.load(it) }
            }
        }
    }
}
