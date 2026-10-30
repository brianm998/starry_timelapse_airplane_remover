package com.star.desktop.ui.sequence

import androidx.compose.ui.graphics.ImageBitmap
import com.star.desktop.i18n.localized
import com.star.desktop.data.ExportRepository
import com.star.desktop.data.FrameRepository
import com.star.desktop.data.HorizonRepository
import com.star.desktop.data.ImageCache
import com.star.desktop.data.OutlierRepository
import com.star.desktop.data.ProcessingRepository
import com.star.desktop.domain.FastAdvancementType
import com.star.desktop.domain.InteractionMode
import com.star.desktop.domain.MultiFrameRange
import com.star.desktop.domain.OutlierTable
import com.star.desktop.domain.ToolType
import com.star.desktop.domain.toolAfterCleanMethodChange
import com.star.desktop.domain.usesOutliers
import com.star.desktop.domain.VideoPlayMode
import com.star.desktop.util.Log
import com.star.proto.FrameProcessingState
import com.star.proto.FrameViewMode
import com.star.proto.ProgressEvent
import com.star.proto.SessionInfo
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import com.star.desktop.ui.components.HorizonLineKinds
import com.star.proto.HorizonOverlayKind
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.debounce
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.launchIn
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.onEach
import kotlinx.coroutines.flow.sample
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

/**
 * Per-session UI state (macOS `ImageSequenceViewModel`): interaction mode, current frame, selection,
 * tool, view mode, panel visibility, playback, plus the live processing state folded from the
 * progress stream. Preview loading auto-retries as processing makes a frame's preview available.
 */
class SequenceViewModel(
    parentScope: CoroutineScope,
    val info: SessionInfo,
    private val frames: FrameRepository,
    val processing: ProcessingRepository,
    val outliers: OutlierRepository,
    private val imageCache: ImageCache,
    private val export: ExportRepository,
    val horizon: HorizonRepository,
    /** Shows a failed user action to the user (macOS `report(error:)`). */
    private val onError: (String) -> Unit = {},
    /** The user's stored preferences (the horizon line's visibility is one); null where there are none, as in tests. */
    private val prefs: com.star.desktop.data.LocalPreferences? = null,
    /** The sequence's alignment results as the daemon has them now (`Alignment.GetSequence`); null where there are none, as in tests. */
    private val alignmentSource: (suspend () -> com.star.proto.AlignmentSequence?)? = null,
) {
    val sessionId: String = info.sessionId
    val frameCount: Int = info.frameCount

    /**
     * Everything this view model launches runs here, a child of [parentScope] that [close] cancels,
     * so nothing it started outlives its session (the app's own scope lives as long as the app).
     */
    private val scope: CoroutineScope =
        CoroutineScope(parentScope.coroutineContext + SupervisorJob(parentScope.coroutineContext[Job]))

    /**
     * The zoom and pan of the frame, one for the session: shared by the edit view and the horizon painter, and not
     * reset when the frame changes (macOS keeps `currentZoomScale` on its view model too).
     */
    val transform = com.star.desktop.ui.sequence.edit.FrameTransform(
        info.imageWidth, info.imageHeight,
        margin = info.imageWidth / ARROW_LENGTH_DIVISOR, // the outlier arrows reach this far outside the frame
    )

    // ---- interaction state ----
    private val _mode = MutableStateFlow(InteractionMode.SCRUB) // macOS default is scrub
    val mode: StateFlow<InteractionMode> = _mode.asStateFlow()

    private val _currentIndex = MutableStateFlow(0)
    val currentIndex: StateFlow<Int> = _currentIndex.asStateFlow()

    private val _selected = MutableStateFlow<Set<Int>>(emptySet())
    val selected: StateFlow<Set<Int>> = _selected.asStateFlow()

    private val _tool = MutableStateFlow(ToolType.REMOVE)
    val tool: StateFlow<ToolType> = _tool.asStateFlow()

    // The original frames, as macOS opens every sequence (its `frameViewMode` default); the processed ones are a click away.
    private val _viewMode = MutableStateFlow(FrameViewMode.VIEW_ORIGINAL)
    val viewMode: StateFlow<FrameViewMode> = _viewMode.asStateFlow()

    private val _showFilmstrip = MutableStateFlow(true)
    val showFilmstrip: StateFlow<Boolean> = _showFilmstrip.asStateFlow()

    // Grid thumbnail size (macOS gridThumbnailScale): a fraction of the full image width, 0.02..0.5.
    private val _gridThumbnailScale = MutableStateFlow(0.12f)
    val gridThumbnailScale: StateFlow<Float> = _gridThumbnailScale.asStateFlow()
    fun setGridThumbnailScale(v: Float) { _gridThumbnailScale.value = v.coerceIn(0.02f, 0.5f) }

    // Draw the horizon line on the frame, the filmstrip and the grid (macOS showHorizonOnMainView, which is stored: the
    // choice is the user's and outlives the session).
    private val _showHorizonOnMainView = MutableStateFlow(prefs?.showHorizonOnMainView ?: false)
    val showHorizonOnMainView: StateFlow<Boolean> = _showHorizonOnMainView.asStateFlow()
    fun setShowHorizonOnMainView(show: Boolean) {
        _showHorizonOnMainView.value = show
        prefs?.showHorizonOnMainView = show
    }

    // Which kinds of horizon line are drawn when they are shown (macOS hiddenHorizonLineKinds, stored in the same file).
    private val _visibleHorizonLineKinds =
        MutableStateFlow(HorizonLineKinds.visible(prefs?.hiddenHorizonLineKinds ?: emptyList()))
    val visibleHorizonLineKinds: StateFlow<Set<HorizonOverlayKind>> = _visibleHorizonLineKinds.asStateFlow()
    fun setHorizonLineKindVisible(kind: HorizonOverlayKind, visible: Boolean) {
        val shown = if (visible) _visibleHorizonLineKinds.value + kind else _visibleHorizonLineKinds.value - kind
        _visibleHorizonLineKinds.value = shown
        prefs?.hiddenHorizonLineKinds = HorizonLineKinds.all.filter { it !in shown }.mapNotNull { HorizonLineKinds.key(it) }
    }

    private val _leftPanelShowing = MutableStateFlow(true)
    val leftPanelShowing: StateFlow<Boolean> = _leftPanelShowing.asStateFlow()
    private val _rightPanelShowing = MutableStateFlow(true)
    val rightPanelShowing: StateFlow<Boolean> = _rightPanelShowing.asStateFlow()
    fun setLeftPanel(showing: Boolean) { _leftPanelShowing.value = showing }
    fun setRightPanel(showing: Boolean) { _rightPanelShowing.value = showing }
    /** Which right panel sections are open; all start open. Here, not in the panel, because the panel is dropped while hidden. */
    private val _expandedRightPanelSections = MutableStateFlow(RightPanelSection.entries.toSet())
    val expandedRightPanelSections: StateFlow<Set<RightPanelSection>> = _expandedRightPanelSections.asStateFlow()
    fun toggleRightPanelSection(section: RightPanelSection) {
        val open = _expandedRightPanelSections.value
        _expandedRightPanelSections.value = if (section in open) open - section else open + section
    }
    /** macOS `toggleSidePanels` (Tab): both shown → both hide; otherwise → both show. */
    fun toggleSidePanels() {
        val hide = _leftPanelShowing.value && _rightPanelShowing.value
        _leftPanelShowing.value = !hide
        _rightPanelShowing.value = !hide
    }

    /** What the multi-frame sheets were last left with, so the next one starts there (E5 of the parity plan). */
    val multiSheetMemory = com.star.desktop.ui.dialogs.MultiSheetMemory()

    // Edit sub-mode: when on, the center view is the horizon painter instead of the outlier overlay.
    private val _horizonPaintMode = MutableStateFlow(false)
    val horizonPaintMode: StateFlow<Boolean> = _horizonPaintMode.asStateFlow()
    fun toggleHorizonPaint() { _horizonPaintMode.value = !_horizonPaintMode.value; _horizonPaintStarted.value = false }

    // Paint on a horizon reference belongs to the frame it was painted on: once there is any, moving off the frame is held back and asked
    // about (macOS `horizonPaintingStarted` / `pendingHorizonFrameChange`).
    private val _horizonPaintStarted = MutableStateFlow(false)
    fun setHorizonPaintStarted(started: Boolean) { _horizonPaintStarted.value = started }
    private val _pendingHorizonFrameChange = MutableStateFlow<Int?>(null)
    /** The frame a change was headed for when it was held back; non-null while the "change frame?" dialog is up. */
    val pendingHorizonFrameChange: StateFlow<Int?> = _pendingHorizonFrameChange.asStateFlow()
    fun confirmHorizonFrameChange() {
        val target = _pendingHorizonFrameChange.value ?: return
        _pendingHorizonFrameChange.value = null
        _horizonPaintStarted.value = false
        setCurrentIndex(target, confirmed = true)
    }
    fun cancelHorizonFrameChange() { _pendingHorizonFrameChange.value = null }

    // ---- startup horizon flow (macOS horizonPainterMode == .startup + startup frame indices/position) ----
    // When true the painter shows "i / N" progress + Next/Continue and the AppViewModel routes the
    // painter exit back into the startup prompt chain (→ removal, or back to the moving question).
    private val _horizonPainterStartup = MutableStateFlow(false)
    val horizonPainterStartup: StateFlow<Boolean> = _horizonPainterStartup.asStateFlow()
    // The evenly-spaced frames to paint (empty = a single static frame, the one currently shown).
    private val _startupHorizonIndices = MutableStateFlow<List<Int>>(emptyList())
    val startupHorizonIndices: StateFlow<List<Int>> = _startupHorizonIndices.asStateFlow()
    // Position within [startupHorizonIndices] currently being painted.
    private val _startupHorizonPosition = MutableStateFlow(0)
    val startupHorizonPosition: StateFlow<Int> = _startupHorizonPosition.asStateFlow()

    /**
     * Enter startup horizon-painting on [indices], at [position] within them.
     *
     * [position] is 0 for a selection that is only just starting, and whatever the config
     * recorded for one a previous session left unfinished — see `AppViewModel.onOpened`.
     * The static flow passes a single frame rather than an empty list, so that it records
     * and resumes by the same route; everything that tells the two flows apart asks for
     * `size > 1`, and `startupHorizonHasMore` is false either way.
     */
    fun beginStartupHorizon(indices: List<Int>, position: Int = 0) {
        _startupHorizonIndices.value = indices
        _startupHorizonPosition.value = position
        _horizonPainterStartup.value = true
        indices.getOrNull(position)?.let { setCurrentIndex(it, confirmed = true) }
        _mode.value = InteractionMode.EDIT
        _horizonPaintMode.value = true
    }

    /** True when more startup frames remain to paint after the current one. */
    fun startupHorizonHasMore(): Boolean {
        val idx = _startupHorizonIndices.value
        return idx.isNotEmpty() && _startupHorizonPosition.value + 1 < idx.size
    }

    /** Advance to the next startup horizon frame (macOS `advanceToNextStartupHorizonFrame`). */
    fun advanceStartupHorizon() {
        val idx = _startupHorizonIndices.value
        val next = _startupHorizonPosition.value + 1
        if (next >= idx.size) return
        _startupHorizonPosition.value = next
        setCurrentIndex(idx[next], confirmed = true)
    }

    /** Leave startup horizon-painting and close the painter (macOS resets horizonPainterMode to .normal). */
    fun endStartupHorizon() {
        _horizonPainterStartup.value = false
        _startupHorizonIndices.value = emptyList()
        _startupHorizonPosition.value = 0
        _horizonPaintMode.value = false
        _horizonPaintStarted.value = false
        _mode.value = InteractionMode.SCRUB
    }

    // ---- processing state (delegated) ----
    val frameStates: StateFlow<Map<Int, FrameProcessingState>> = processing.frameStates
    val isProcessing: StateFlow<Boolean> = processing.processing

    /** How many frames have edits being saved or waiting to be (see [com.star.desktop.data.ProcessingRepository.pendingSaves]). */
    val pendingSaves: StateFlow<Int> = processing.pendingSaves

    /**
     * The sequence's alignment results, kept up to date while anything is showing them (the Alignment window, the left panel's chart, the
     * processing screen): fetched when the first of those appears, and again at most once a second as the frames' states change, since
     * alignment finishes frame by frame as a run goes. Null until the first fetch arrives, or when there is nothing to fetch it with.
     */
    val alignment: StateFlow<com.star.desktop.domain.AlignmentData?> = alignmentFlow()
        .map { seq -> seq?.let { com.star.desktop.domain.AlignmentData(it.framesList) } }
        .stateIn(scope, SharingStarted.WhileSubscribed(stopTimeoutMillis = 10_000), null)

    @OptIn(kotlinx.coroutines.FlowPreview::class)
    private fun alignmentFlow(): kotlinx.coroutines.flow.Flow<com.star.proto.AlignmentSequence?> {
        val source = alignmentSource ?: return kotlinx.coroutines.flow.flowOf(null)
        return kotlinx.coroutines.flow.flow {
            emit(source())
            processing.frameStates.sample(ALIGNMENT_REFRESH_MS).collect { emit(source()) }
        }
    }

    /** How far each step of the run in progress has got (see [ProcessingRepository.stepProgress]). */
    val stepProgress: StateFlow<com.star.proto.StepProgress?> = processing.stepProgress

    /** Whether each frame's outliers are loading (1) or in memory (2), as the daemon reports it; a frame not listed has them on disk. */
    val outlierLoadState: StateFlow<Map<Int, Int>> = processing.outlierLoadState

    /** Each frame's stage of being saved after an edit (0 not saving, 1 purgatory, 2 waiting, 3 saving): see [com.star.desktop.domain.SavingCounts]. */
    val savingState: StateFlow<Map<Int, Int>> = processing.savingState
    val sequenceState: StateFlow<String?> = processing.sequenceState

    // ---- processing progress screen (macOS `ProcessingModalView`) ----
    //
    // Dismissing it (see dismissProcessingModal) only hides the screen — the run keeps going in the
    // background, and results can be inspected while other frames still process. Stopping the run
    // (cancelProcessing) is a separate action. Re-armed on every new run, so a modal dismissed on
    // one run still shows for the next.
    private val _processingModalDismissed = MutableStateFlow(false)
    private val _showProcessingModal = MutableStateFlow(false)
    val showProcessingModal: StateFlow<Boolean> = _showProcessingModal.asStateFlow()
    fun dismissProcessingModal() { _processingModalDismissed.value = true }

    /** Put the processing screen back up after it was dismissed (macOS LeftPanel's Status button); a run in progress always has a status to show. */
    fun reopenProcessingModal() { _processingModalDismissed.value = false }

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

    /** How many frames the fast buttons move by in the normal strategy (macOS `fastSkipAmount`, 20 to start with; not kept between runs). */
    private val _fastSkipAmount = MutableStateFlow(FastAdvancementType.DEFAULT_SKIP_AMOUNT)
    val fastSkipAmount: StateFlow<Int> = _fastSkipAmount.asStateFlow()
    fun setFastSkipAmount(n: Int) { _fastSkipAmount.value = n.coerceIn(0, FastAdvancementType.MAX_SKIP_AMOUNT) }
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
        frameVMs.getOrPut(index) { FrameViewModel(scope, sessionId, index, outliers, frames, onError) }

    /** The frame view model for the current index. */
    fun currentFrameVM(): FrameViewModel = frameVMFor(_currentIndex.value)

    /**
     * Bumped for a frame each time a picture of it is saved. Grid and filmstrip cells load their thumbnail
     * keyed on this, so a rewritten preview replaces the one they show.
     */
    private val _frameRevisions = MutableStateFlow<Map<Int, Int>>(emptyMap())
    val frameRevisions: StateFlow<Map<Int, Int>> = _frameRevisions.asStateFlow()

    private fun bumpRevision(index: Int) {
        _frameRevisions.value = _frameRevisions.value.let { it + (index to ((it[index] ?: 0) + 1)) }
    }

    /**
     * Bumped for a frame each time what this client holds of it is marked out of date ([frameDataChanged]): a processing state change,
     * its outliers loading, or a bulk edit. The filmstrip and grid cells fetch the frame's counts again on it.
     */
    private val _frameDataVersions = MutableStateFlow<Map<Int, Int>>(emptyMap())
    val frameDataVersions: StateFlow<Map<Int, Int>> = _frameDataVersions.asStateFlow()

    /**
     * The state, counts and clean method of frame [index], live. Every edit made to the frame lands in this one flow (the edit view's
     * decisions, Keep All, a clean-method change, a bulk edit), so a cell that draws from it follows them; a cell that kept its own copy,
     * fetched when the frame's index or state changed, went on showing the outlier ticks it had before the edit (Q11).
     */
    fun frameInfoFlow(index: Int): StateFlow<com.star.proto.FrameInfo?> = frameVMFor(index).info

    /** Fetch frame [index]'s info from the daemon into [frameInfoFlow]. */
    suspend fun refreshFrameInfo(index: Int) {
        frameInfo(index)?.let { frameVMFor(index).applyInfo(it) }
    }

    // State the `init` block's collectors read the moment they start; a property declared below it would still be null then.
    private val _showFullResolution = MutableStateFlow(false)
    val showFullResolution: StateFlow<Boolean> = _showFullResolution.asStateFlow()
    fun setShowFullResolution(show: Boolean) { _showFullResolution.value = show }

    private val _fullResolution = MutableStateFlow<ImageBitmap?>(null)
    /** The current frame's full-size image while [showFullResolution] is on and the view is zoomed in; else null. */
    val fullResolution: StateFlow<ImageBitmap?> = _fullResolution.asStateFlow()
    private var fullResolutionJob: Job? = null
    private val fullResolutionVersion = MutableStateFlow(0)

    /** Whether any refinement is waiting: what enables "Re-run Horizon Refinement". */
    private val _refinementPending = MutableStateFlow(false)
    val refinementPending: StateFlow<Boolean> = _refinementPending.asStateFlow()

    /**
     * Bumped whenever a frame's horizon, or whether it is pending, may have changed: a reference was saved, the question was
     * answered, a refinement operation finished. Overlays that draw a frame's horizon load it keyed on this.
     */
    private val _horizonVersion = MutableStateFlow(0)
    val horizonVersion: StateFlow<Int> = _horizonVersion.asStateFlow()
    // ---- frames that are still being extracted from a video ----

    /** How far the extraction has got; null for an image sequence. Complete when every frame is there. */
    val extraction: StateFlow<com.star.proto.FrameExtraction?> = processing.extraction

    /** The frames that are extracted, while the video is still being extracted; null when every frame is there. */
    val extractedFrames: StateFlow<com.star.desktop.domain.ExtractedFrames?> = processing.extractedFrames

    /** Whether frame [index] is extracted (an image sequence's frames all are). */
    fun isFrameExtracted(index: Int): Boolean = processing.extractedFrames.value?.contains(index) ?: true

    /** Whether the video is still being extracted (the progress bar is up, and frames may be missing). */
    val isExtracting: StateFlow<Boolean> = combine(processing.extraction, processing.extractedFrames) { e, frames ->
        e != null && (!e.complete && frames != null || e.error.isNotEmpty())
    }.stateIn(scope, SharingStarted.Eagerly, false)

    /** How long until [index] is extracted, for the wait panel; null when the engine could not say. */
    suspend fun frameEta(index: Int): com.star.proto.FrameEtaResponse? = frames.eta(sessionId, index)

    init {
        // Subscribe to progress BEFORE any Processing.Start (the daemon attaches its continuation lazily).
        processing.subscribe(sessionId)
        processing.seedExtraction(info.extraction)

        // The frame on screen, and the ones around it, are what a video that is still being extracted fetches first (where its format
        // allows it). Settled for a moment first, so a scrub that is moving does not ask for every frame it passes over.
        scope.launch {
            _currentIndex.collectLatest { idx ->
                delay(PRIORITIZE_DEBOUNCE_MS)   // a newer frame cancels this one before it asks
                if (processing.extractedFrames.value == null) return@collectLatest
                val reach = PRIORITIZE_REACH
                frames.prioritize(sessionId, idx, listOf((idx - reach).coerceAtLeast(0)..(idx + reach).coerceAtMost(frameCount - 1)))
            }
        }

        // The frame on screen was not there and now is: show it.
        processing.extractedFrames
            .map { it?.contains(_currentIndex.value) ?: true }
            .distinctUntilChanged()
            .onEach { here -> if (here) loadPreview(_currentIndex.value, _viewMode.value) }
            .launchIn(scope)

        // (Re)load the current preview whenever the index or view mode changes.
        combine(_currentIndex, _viewMode) { idx, mode -> idx to mode }
            .distinctUntilChanged()
            .onEach { (idx, mode) -> loadPreview(idx, mode) }
            .launchIn(scope)

        // The label map used to find the outlier under the pointer is large, and one per frame visited was kept
        // for good. Only the frames around the current one are likely to be wanted again soon.
        _currentIndex
            .onEach { current ->
                frameVMs.forEach { (i, vm) -> if (kotlin.math.abs(i - current) > LABEL_RETENTION) vm.releaseLabels() }
            }
            .launchIn(scope)

        watchFullResolution()

        // `stard` rewrites a frame's previews in place when it saves one: drop what is cached for it and, if
        // it is the one on screen, show the new picture.
        processing.imageSaved
            .onEach { saved ->
                imageCache.invalidateFrame(saved.frameIndex)
                // Every image the pipeline keeps is announced when it is written (the aligned frames, the masks...); only the ones
                // that can be on screen are worth redrawing it for: the one being shown, and the original and final of the thumbnails.
                if (saved.viewMode != _viewMode.value &&
                    saved.viewMode != FrameViewMode.VIEW_PROCESSED && saved.viewMode != FrameViewMode.VIEW_ORIGINAL
                ) return@onEach
                bumpRevision(saved.frameIndex)
                if (saved.frameIndex == _currentIndex.value) {
                    loadPreview(saved.frameIndex, _viewMode.value)
                    fullResolutionVersion.value++   // the full-size copy is of the old picture
                }
            }
            .launchIn(scope)

        // A frame whose processing state changed has new pictures, new outliers or new counts. The one on
        // screen is reloaded at once (also upgrading an original shown as a stand-in for a processed
        // frame); the others are fetched afresh when next looked at.
        var lastStates = emptyMap<Int, FrameProcessingState>()
        processing.frameStates
            .onEach { states ->
                val changed = states.filter { (i, s) -> lastStates[i] != s }.keys
                lastStates = states
                changed.forEach { frameDataChanged(it) }
                if (_currentIndex.value in changed) loadPreview(_currentIndex.value, _viewMode.value)
            }
            .launchIn(scope)

        // Outliers loading into memory (after being purged to disk) changes what the frame's counts mean.
        var lastLoad = emptyMap<Int, Int>()
        processing.outlierLoadState
            .onEach { loads ->
                val changed = loads.filter { (i, s) -> lastLoad[i] != s }.keys
                lastLoad = loads
                changed.forEach { frameDataChanged(it) }
            }
            .launchIn(scope)

        // A run that ends (done, stopped, failed) may have taken the pending refinement or given it back.
        processing.sequenceState
            .onEach { if (it != null) { refreshRefinementStatus(); horizonChanged() } }
            .launchIn(scope)

        // A frame's horizon lines changed (a mask written or deleted, a reference painted or cleared, a refinement finished).
        // They change by the thousand while a run writes the horizon consensus, so the horizons are redrawn at most twice a second
        // while they do — sampled rather than debounced, which would wait for the whole burst to end.
        @OptIn(kotlinx.coroutines.FlowPreview::class)
        processing.horizonUpdated
            .sample(500)
            .onEach { horizonChanged() }
            .launchIn(scope)

        combine(isProcessing, _processingModalDismissed) { processingNow, dismissed -> processingNow && !dismissed }
            .onEach { _showProcessingModal.value = it }
            .launchIn(scope)
    }

    /**
     * What this client holds of frame [index] (groups, decisions, counts) is out of date. Marked as such, and
     * fetched again right away if it is the frame on screen.
     */
    private fun frameDataChanged(index: Int) {
        _frameDataVersions.update { it + (index to ((it[index] ?: 0) + 1)) }
        val vm = frameVMs[index] ?: return
        vm.invalidate()
        if (index == _currentIndex.value) vm.load(force = true)
    }

    /** The daemon changed these frames (it sends their new counts back with a bulk edit). */
    private fun framesChanged(infos: List<com.star.proto.FrameInfo>) {
        for (info in infos) {
            frameVMs[info.frameIndex]?.applyInfo(info)
            frameDataChanged(info.frameIndex)
        }
    }

    // ---- actions ----
    fun setMode(m: InteractionMode) { _mode.value = m }
    fun setViewMode(m: FrameViewMode) { _viewMode.value = m }
    /**
     * Whether the current frame's clean method reviews outliers (macOS `currentFrameUsesOutliers`).
     * The editing tools only apply then; plain automatic mode has nothing for them to act on.
     */
    fun currentFrameUsesOutliers(): Boolean =
        (frameVMFor(_currentIndex.value).info.value?.cleanMethod ?: com.star.proto.CleanMethod.CLEAN_SELECTIVE).usesOutliers

    fun setTool(t: ToolType) {
        if (!currentFrameUsesOutliers()) return
        _tool.value = t
        // Taking things back out of the trash only makes sense with the trash showing (macOS selectionMode's didSet).
        if (t == ToolType.REMOVE_FROM_TRASH) _showTrash.value = true
    }

    // ---- trash (macOS shouldShowTrash / trashOpacity) ----

    /**
     * Whether the trash is shown over the frame and taken into account by the tools: razor, the Remove/Keep boxes, Keep All,
     * Remove All, Clear Undecided, multi-select and DT Auto Only all pass it as `includingTrash`, as macOS does.
     */
    private val _showTrash = MutableStateFlow(false)
    val showTrash: StateFlow<Boolean> = _showTrash.asStateFlow()
    fun setShowTrash(show: Boolean) { _showTrash.value = show }

    /** How strongly the trash is drawn (macOS default 0.7). */
    private val _trashOpacity = MutableStateFlow(0.7f)
    val trashOpacity: StateFlow<Float> = _trashOpacity.asStateFlow()
    fun setTrashOpacity(v: Float) { _trashOpacity.value = v.coerceIn(0f, 1f) }

    /** How strongly the outlier groups (and the trash, the boxes, the arrows) are drawn over the frame (macOS default 1). Not kept between runs, as on macOS. */
    private val _outlierOpacity = MutableStateFlow(1f)
    val outlierOpacity: StateFlow<Float> = _outlierOpacity.asStateFlow()
    fun setOutlierOpacity(v: Float) { _outlierOpacity.value = v.coerceIn(0f, 1f) }

    /** How much of the frame shows (macOS default 1): below that it is dimmed with black, so the outliers stand out against it. */
    private val _frameOpacity = MutableStateFlow(1f)
    val frameOpacity: StateFlow<Float> = _frameOpacity.asStateFlow()
    fun setFrameOpacity(v: Float) { _frameOpacity.value = v.coerceIn(0f, 1f) }

    /** The "Multi Choice" switch (macOS `multiChoice`): while it is on, clicking a group that has a decision opens the multi-choice sheet instead of changing it. */
    private val _multiChoiceMode = MutableStateFlow(false)
    val multiChoiceMode: StateFlow<Boolean> = _multiChoiceMode.asStateFlow()
    fun setMultiChoiceMode(on: Boolean) { _multiChoiceMode.value = on }

    /**
     * The session's clean method became [method] (macOS pushes the new effective method to every frame): what each
     * frame view model holds, including its clean method, is out of date, and the tool is reset when the method
     * has no use for one.
     */
    fun cleanMethodChanged(method: com.star.proto.CleanMethod) {
        frameVMs.values.forEach { it.invalidate() }
        frameVMFor(_currentIndex.value).load(force = true)
        _tool.value = toolAfterCleanMethodChange(_tool.value, method)
    }
    fun toggleFilmstrip() { _showFilmstrip.value = !_showFilmstrip.value }

    fun setCurrentIndex(i: Int, confirmed: Boolean = false) {
        val clamped = i.coerceIn(0, (frameCount - 1).coerceAtLeast(0))
        if (!confirmed && _horizonPaintMode.value && _horizonPaintStarted.value && clamped != _currentIndex.value) {
            _pendingHorizonFrameChange.value = clamped
            return
        }
        _currentIndex.value = clamped
    }

    fun next() = stepBy(1)
    fun previous() = stepBy(-1)

    /** [delta] frames on, or back: through the frames selected, round and round, when there are several (macOS `transition(numberOfFrames:)`). */
    private fun stepBy(delta: Int) =
        setCurrentIndex(com.star.desktop.domain.FrameNavigation.step(_currentIndex.value, delta, frameCount, _selected.value))

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

    /**
     * Show a failed user action. Cancellation is not a failure. [message] is what the user is told;
     * it defaults to the error's own text, as macOS `report(error: "\(error)")` does.
     */
    private fun reportFailure(e: Throwable, message: () -> String = { e.message ?: e.toString() }) {
        if (e is kotlinx.coroutines.CancellationException) return
        onError(message())
    }

    fun processAll() = startProcessingRun { processing.start(sessionId, 0, -1) }

    /** From the current frame to the end (macOS `ProcessRemainingFramesButton`); finished work is reused. */
    fun processRemaining() = startProcessingRun { processing.start(sessionId, _currentIndex.value, -1) }

    /** Process the current frame, keeping whatever is already done (macOS `.none` reprocessing). */
    fun processCurrent() = startProcessingRun {
        processing.reprocessFrames(sessionId, listOf(_currentIndex.value), com.star.proto.ReprocessingType.REPROCESS_NONE)
    }

    // ---- "re-process the next N frames" (macOS RightPanel) ----

    /** What to throw away before the frames are processed again (macOS `reprocessingType`: nothing to start with; not kept between runs). */
    private val _reprocessType = MutableStateFlow(com.star.proto.ReprocessingType.REPROCESS_NONE)
    val reprocessType: StateFlow<com.star.proto.ReprocessingType> = _reprocessType.asStateFlow()
    fun setReprocessType(t: com.star.proto.ReprocessingType) { _reprocessType.value = t }

    /** How many frames from this one the button works on (macOS `numberOfFramesToProcess`). */
    private val _framesToProcess = MutableStateFlow(1)
    val framesToProcess: StateFlow<Int> = _framesToProcess.asStateFlow()
    fun setFramesToProcess(n: Int) { _framesToProcess.value = n.coerceIn(1, frameCount.coerceAtLeast(1)) }

    /** Process the current frame and the ones after it, clearing first what [reprocessType] says (macOS "Re-Process the next N"). */
    fun reprocessNext() = startProcessingRun {
        val from = _currentIndex.value
        val indices = (from until (from + _framesToProcess.value).coerceAtMost(frameCount)).toList()
        processing.reprocessFrames(sessionId, indices, _reprocessType.value)
    }

    /**
     * Give the current frame its own neighbour count of [kind], or with a null [count] let the sequence's apply again (macOS
     * `set(alignedNeighborFrames:forFrame:)`). A new aligned count throws the frame's star alignment away and processes it again, so that
     * shows the processing screen like any run; a new static count rebuilds the merged horizon if there was one.
     */
    fun setNeighborOverride(kind: com.star.proto.NeighborKind, count: Int?) {
        val index = _currentIndex.value
        scope.launch {
            try {
                if (kind == com.star.proto.NeighborKind.NEIGHBOR_ALIGNED) {
                    armProcessingModal()
                    processing.startClaimedRun {
                        val answer = frames.setNeighborOverride(sessionId, index, kind, count)
                        frameVMFor(index).applyInfo(answer.frame)
                        answer.processingStarted
                    }
                } else {
                    frameVMFor(index).applyInfo(frames.setNeighborOverride(sessionId, index, kind, count).frame)
                }
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (e: Throwable) {
                reportFailure(e)
            }
        }
    }

    /** Find the outliers of the current frame again, keeping its alignment (macOS `FindOutliersOnCurrentFrameButton`). */
    fun findOutliersCurrent() = startProcessingRun {
        processing.reprocessFrames(sessionId, listOf(_currentIndex.value), com.star.proto.ReprocessingType.REPROCESS_OUTLIERS)
    }

    /** Reprocess the current frame from scratch (macOS `ReProcessCurrentFrameButton`). */
    fun reprocessCurrent() = startProcessingRun {
        processing.reprocessFrames(sessionId, listOf(_currentIndex.value), com.star.proto.ReprocessingType.REPROCESS_EVERYTHING)
    }

    /**
     * Re-arm the processing modal (macOS `startProcessingModal`) before launching a new run: up over the window, unless the user's preference is
     * not to (the Status button still brings it back).
     */
    private fun armProcessingModal() {
        _processingModalDismissed.value = prefs?.showProcessingWindow == false
    }

    private fun startProcessingRun(block: suspend () -> Unit) = scope.launch {
        armProcessingModal()
        block()
    }
    fun cancelProcessing() = scope.launch { processing.cancel(sessionId) }

    /** Stop the run in progress and start it over under the settings as they now are (macOS `updateSettingsAndProcess` over a live run). */
    fun restartProcessing() = startProcessingRun { processing.restart(sessionId, 0, -1) }

    // ---- full resolution (macOS showFullResolution) ----
    //
    // The preview is about 1600 pixels wide, however large the frame is; zoomed in far enough to see single pixels it is a blur.
    // With this on, and the view zoomed in past fit, the frame's full-size image is loaded in its place. It is one 8-bit bitmap
    // for the current frame only (a 42 MP frame is some 170 MB), made by the daemon on demand, and dropped when the frame, the view
    // mode or the zoom changes.

    private fun watchFullResolution() {
        @OptIn(kotlinx.coroutines.FlowPreview::class)
        combine(
            _currentIndex, _viewMode, _showFullResolution,
            androidx.compose.runtime.snapshotFlow { transform.userZoom > ZOOMED_IN }.distinctUntilChanged(),
            fullResolutionVersion,
        ) { index, mode, show, zoomed, _ -> if (show && zoomed) index to mode else null }
            .distinctUntilChanged()
            .onEach { _fullResolution.value = null }   // what was loaded is of another frame, mode or zoom
            .debounce(250)                              // not for every frame of a scrub
            .onEach { wanted -> loadFullResolution(wanted) }
            .launchIn(scope)
    }

    private fun loadFullResolution(wanted: Pair<Int, FrameViewMode>?) {
        fullResolutionJob?.cancel()
        if (wanted == null) return
        fullResolutionJob = scope.launch {
            val ref = frames.previewPath(sessionId, wanted.first, wanted.second, com.star.proto.PreviewSize.PREVIEW_SIZE_ORIGINAL, buildIfMissing = true)
                ?: return@launch
            val bitmap = imageCache.loadUncached(ref.path) ?: return@launch
            if (_currentIndex.value == wanted.first && _viewMode.value == wanted.second) _fullResolution.value = bitmap
        }
    }

    // ---- the outlier window (macOS outlierGroupTableRows / outlierGroupWindowFrame) ----

    /**
     * What the outlier window lists: [groupIds] of [frameIndex], as set by an Information click or box (macOS lists only those and
     * keeps showing that frame when the user moves on); or, with [groupIds] null, every group of the frame being looked at that
     * is a thing of its own on screen.
     */
    data class InfoRows(val frameIndex: Int, val groupIds: List<Int>?)

    private val _infoRows = MutableStateFlow<InfoRows?>(null)
    val infoRows: StateFlow<InfoRows?> = _infoRows.asStateFlow()

    /** Raises the outlier window; set by the app, which owns windows. */
    var openOutlierWindow: () -> Unit = {}

    /**
     * Show [groupIds] of the current frame in the outlier window. [select] also selects them, and only them, on the frame (an Information
     * click: macOS "turns off other highlights"); a box leaves the selection to the rows the user picks.
     */
    fun showInfoFor(groupIds: List<Int>, select: Boolean = false) {
        val frame = _currentIndex.value
        if (select) {
            frameVMs.values.forEach { if (it.frameIndex != frame) it.selectGroups(emptySet()) }
            frameVMFor(frame).selectGroups(groupIds.toSet())
        }
        _infoRows.value = InfoRows(frame, groupIds)
        openOutlierWindow()
    }

    /**
     * The decision-tree features and classifier scores the outlier window tabulates for [groupIds] of a frame, by group id. Nothing for no
     * groups (an empty request means all of them to the daemon), and nothing when they could not be had, which is shown as an error.
     */
    suspend fun outlierFeatures(frameIndex: Int, groupIds: List<Int>): Map<Int, com.star.proto.OutlierFeatureRow> {
        if (groupIds.isEmpty()) return emptyMap()
        return try {
            outliers.features(sessionId, frameIndex, groupIds).associateBy { it.groupId }
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (e: Throwable) {
            reportFailure(e)
            emptyMap()
        }
    }

    /** The lines the Hough finder proposes for one group, best fit first; nothing when they could not be had. */
    suspend fun lineCandidates(frameIndex: Int, groupId: Int): List<com.star.proto.LineCandidate> =
        failureAsEmpty { outliers.lineCandidates(sessionId, frameIndex, groupId) }

    /** Make [candidate] the line of a group: the frame's drawing of its streak line follows. */
    fun setOutlierLine(frameIndex: Int, groupId: Int, candidate: com.star.proto.LineCandidate) {
        scope.launch {
            try {
                frameVMFor(frameIndex).groupChanged(outliers.setLine(sessionId, frameIndex, groupId, candidate))
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (e: Throwable) {
                reportFailure(e)
            }
        }
    }

    /** The Hough line finder's arguments, as the daemon has them. */
    suspend fun houghArgs(): List<com.star.proto.HoughLineFinderArg> = failureAsEmpty { outliers.houghArgs() }

    /** Set one of the finder's arguments; all of them as they are then. (Empty, and an error shown, if the daemon refused it.) */
    suspend fun setHoughArg(name: String, value: Double): List<com.star.proto.HoughLineFinderArg> =
        failureAsEmpty { outliers.setHoughArg(name, value) }

    private suspend fun <T> failureAsEmpty(block: suspend () -> List<T>): List<T> =
        try {
            block()
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (e: Throwable) {
            reportFailure(e)
            emptyList()
        }

    /** The window was closed: back to listing the frame being looked at, and nothing stays highlighted for it (macOS `onDisappear`). */
    fun outlierWindowClosed() {
        _infoRows.value = null
        frameVMs.values.forEach { it.selectGroups(emptySet()) }
    }

    /** The optional columns of the outlier table that are showing, by [OutlierTable.Column.key]: remembered between runs. */
    private val _outlierColumns = MutableStateFlow(prefs?.strings(OUTLIER_COLUMNS_KEY)?.toSet() ?: OutlierTable.defaultColumns)
    val outlierColumns: StateFlow<Set<String>> = _outlierColumns.asStateFlow()

    fun setOutlierColumn(key: String, shown: Boolean) =
        setOutlierColumns(if (shown) _outlierColumns.value + key else _outlierColumns.value - key)

    /** Select All / Clear All in the column chooser. */
    fun setAllOutlierColumns(shown: Boolean) = setOutlierColumns(if (shown) OutlierTable.columns.map { it.key }.toSet() else emptySet())

    private fun setOutlierColumns(keys: Set<String>) {
        _outlierColumns.value = keys
        prefs?.setStrings(OUTLIER_COLUMNS_KEY, OutlierTable.columns.map { it.key }.filter { it in keys })
    }

    // ---- horizon refinement: the work owed after a reference horizon is repainted ----
    //
    // The daemon keeps the record (which frames are pending, what "later" took away); this is the question put to the
    // user and the bookkeeping the screen needs. The prompt is hosted by the sequence screen, not by the painter, which
    // closes when it saves.

    /** What the "re-run the refinement now, or later?" question quotes. */
    data class RefinementPrompt(val frameCount: Int, val renderCount: Int)

    private val _refinementPrompt = MutableStateFlow<RefinementPrompt?>(null)
    val refinementPrompt: StateFlow<RefinementPrompt?> = _refinementPrompt.asStateFlow()

    fun horizonChanged() { _horizonVersion.value++ }

    /**
     * The painter saved frame [frameIndex]'s reference. With [applyToNearby] the daemon marks the frames that interpolate from
     * it, and if there is anything to redo this asks the user whether to do it now.
     */
    fun horizonReferenceSaved(frameIndex: Int, applyToNearby: Boolean) {
        scope.launch {
            val answer = runCatching { horizon.referenceUpdated(sessionId, frameIndex, applyToNearby) }
                .onFailure { reportFailure(it) }.getOrNull()
            refreshRefinementStatus()
            horizonChanged()
            if (answer != null && (answer.affectedFrameCount > 0 || answer.renderCount > 0)) {
                _refinementPrompt.value = RefinementPrompt(answer.affectedFrameCount, answer.renderCount)
            }
        }
    }

    /** "Later": the work stays pending, minus the renders and masks the old horizon went into. */
    fun deferHorizonRefinement() {
        _refinementPrompt.value = null
        scope.launch {
            runCatching { horizon.deferRefinement(sessionId) }.onFailure { reportFailure(it) }
            refreshRefinementStatus()
            horizonChanged()
        }
    }

    /** "Now" / "Re-run Horizon Refinement": queue the pending work as a run, with the processing modal as for any run. */
    fun runHorizonRefinement() {
        _refinementPrompt.value = null
        startProcessingRun {
            runCatching { processing.startClaimedRun { horizon.runRefinement(sessionId) } }.onFailure { reportFailure(it) }
            refreshRefinementStatus()
            horizonChanged()
        }
    }

    private suspend fun refreshRefinementStatus() {
        _refinementPending.value = horizon.refinementPending(sessionId)
    }

    // ---- decision tree (macOS classifyOnlyUnclassified / minimumClassificationSize) ----

    /**
     * When on (the default), the decision tree only decides groups nobody has decided about, and leaves the
     * user's own keeps and removes alone; off, it reclassifies everything.
     */
    private val _classifyOnlyUnclassified = MutableStateFlow(true)
    val classifyOnlyUnclassified: StateFlow<Boolean> = _classifyOnlyUnclassified.asStateFlow()
    fun setClassifyOnlyUnclassified(only: Boolean) { _classifyOnlyUnclassified.value = only }

    /** Run the decision tree over the current frame's outliers, then render it (macOS "Decision Tree All", `d`; "DT Auto Only"). */
    fun applyDecisionTreeToCurrentFrame(autoOnly: Boolean = false) {
        if (!currentFrameUsesOutliers()) return
        currentFrameVM().applyDecisionTree(
            overwrite = !_classifyOnlyUnclassified.value,
            autoOnly = autoOnly,
            minimumSize = MINIMUM_CLASSIFICATION_SIZE,
            includingTrash = _showTrash.value,
        )
    }

    /** Run the decision tree across every frame, with the same settings as for one. */
    fun applyDecisionTreeAll() = scope.launch {
        runCatching {
            outliers.applyDecisionTreeAllFrames(sessionId, overwrite = !_classifyOnlyUnclassified.value, minimumSize = MINIMUM_CLASSIFICATION_SIZE)
        }
            .onSuccess { framesChanged(it.framesList) }
            .onFailure { reportFailure(it) { localized("ui.decision_tree_render_failed", it.message ?: it) } }
    }

    /** Granular reprocess (grid context menu) of the selected frames, or the current frame if none. */
    fun reprocessSelected(type: com.star.proto.ReprocessingType) {
        val indices = (_selected.value.takeIf { it.isNotEmpty() } ?: setOf(_currentIndex.value)).sorted()
        // Like every run, this shows the processing screen again (macOS startProcessingModal).
        startProcessingRun {
            runCatching { processing.reprocessFrames(sessionId, indices, type) }
                .onFailure { reportFailure(it) }
        }
    }

    /**
     * Save a reference horizon for [frameIndex] without anyone waiting for it: the painter closing keeps what was painted,
     * and the painter's own coroutines are gone by then. A failure is only logged (macOS `try?`).
     */
    fun saveHorizonReferenceInBackground(frameIndex: Int, horizonY: List<Int>, width: Int, height: Int) {
        if (horizonY.none { it >= 0 }) return
        scope.launch {
            runCatching { horizon.setReference(sessionId, frameIndex, horizonY, width, height, setStaticReference = false) }
                .onFailure { Log.w("Horizon") { "saving the reference horizon of frame $frameIndex on close failed: ${it.message}" } }
        }
    }

    /** A frame's horizon overlay (kind, per-column Y, whether it is pending refinement) computed at [width] columns, or null if none. */
    suspend fun horizonOverlay(index: Int, width: Int, height: Int) =
        horizon.getOverlay(sessionId, index, width, height)

    /**
     * The view modes that have an image on disk for [index], from the daemon's own list: drives the left panel's "Show" list and
     * greys out the pills of a mode the frame does not have (macOS `FrameViewModel.hasImage(type:)`). The original is always there;
     * the rest appear as processing writes them. Asking for a preview of each to find out would generate the ones that were missing.
     */
    suspend fun availableViewModes(index: Int): List<FrameViewMode> =
        runCatching { frames.info(sessionId, index).availableModesList }.getOrNull()?.ifEmpty { null } ?: listOf(FrameViewMode.VIEW_ORIGINAL)

    // ---- multi-frame outlier sheets (macOS MultiChoice / MultiSelect) ----
    data class MultiChoiceTarget(val frameIndex: Int, val groupId: Int, val currentlyRemoves: Boolean)
    data class RectSelection(val startX: Float, val startY: Float, val endX: Float, val endY: Float)

    private val _multiChoice = MutableStateFlow<MultiChoiceTarget?>(null)
    val multiChoice: StateFlow<MultiChoiceTarget?> = _multiChoice.asStateFlow()
    private val _multiSelect = MutableStateFlow<RectSelection?>(null)
    val multiSelect: StateFlow<RectSelection?> = _multiSelect.asStateFlow()

    fun openMultiChoice(frameIndex: Int, groupId: Int, currentlyRemoves: Boolean) {
        _multiChoice.value = MultiChoiceTarget(frameIndex, groupId, currentlyRemoves)
    }
    fun openMultiSelect(sel: RectSelection) { _multiSelect.value = sel }
    fun dismissMultiSheets() { _multiChoice.value = null; _multiSelect.value = null }

    /** Apply a keep/remove to outliers overlapping the chosen group across [range] (multi-choice sheet). */
    fun applyMultiChoice(shouldRemove: Boolean, range: MultiFrameRange, n: Int) = scope.launch {
        val t = _multiChoice.value ?: return@launch
        val (s, e) = range.indices(_currentIndex.value, frameCount, n)
        runCatching { outliers.setDecisionsOverlapping(sessionId, s, e, shouldRemove, t.frameIndex, t.groupId) }
            .onSuccess { framesChanged(it.framesList) }
            .onFailure { reportFailure(it) }
        dismissMultiSheets()
    }

    /** Apply a keep/remove to outliers in the drag rectangle across [range] (multi-select sheet). */
    fun applyMultiSelect(shouldRemove: Boolean, overlapping: Boolean, range: MultiFrameRange, n: Int, includingTrash: Boolean = _showTrash.value) = scope.launch {
        val sel = _multiSelect.value ?: return@launch
        val (s, e) = range.indices(_currentIndex.value, frameCount, n)
        runCatching { outliers.setDecisionsInArea(sessionId, s, e, shouldRemove, sel.startX, sel.startY, sel.endX, sel.endY, overlapping, includingTrash) }
            .onSuccess { framesChanged(it.framesList) }
            .onFailure { reportFailure(it) }
        dismissMultiSheets()
    }

    // ---- render ----
    /** Write the current frame's finished image from its decisions (`Outlier.RenderFrame`) and show it again. */
    fun renderCurrentFrame() = scope.launch {
        if (_rendering.value || isProcessing.value) return@launch
        val idx = _currentIndex.value
        _rendering.value = true
        _renderProgress.value = null // indeterminate: a single frame
        try {
            val ref = outliers.renderFrame(sessionId, idx)
            // The daemon rewrote the frame's final image in place, so the bitmap cached for that path is
            // stale; show the frame again in whatever view is selected (the processed view reads it).
            imageCache.invalidate(ref.path)
            loadPreview(idx, _viewMode.value)
        } catch (e: Throwable) {
            Log.w("Sequence") { "render current frame failed: ${e.message}" }
            reportFailure(e) { localized("ui.render_failed", e.message ?: e) }
        } finally {
            _rendering.value = false
        }
    }

    /**
     * Render every frame's final output (`Export.RenderSequence`). The render stream is its own
     * subscriber on the daemon, so the long-lived progress subscription keeps running throughout.
     */
    fun renderAllFrames() = scope.launch {
        if (_rendering.value || isProcessing.value) return@launch
        _rendering.value = true
        _renderProgress.value = 0f
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
            reportFailure(e) { localized("ui.render_failed", e.message ?: e) }
        } finally {
            _renderProgress.value = null
            _rendering.value = false
        }
    }

    // ---- transport ----
    fun goToFirst() = setCurrentIndex(0)
    fun goToLast() = setCurrentIndex(frameCount - 1)
    fun fastForward() = fastSkip(forward = true)
    fun fastPrevious() = fastSkip(forward = false)

    /**
     * Fast-skip per the active [FastAdvancementType]: NORMAL jumps [fastSkipAmount] frames;
     * the category modes scan frame-by-frame (via `Frame.Get` counts) to the next non-empty frame,
     * stopping at the sequence boundary (macOS `transition(until:)`).
     */
    private fun fastSkip(forward: Boolean) {
        val mode = _fastAdvancement.value
        if (mode == FastAdvancementType.NORMAL) {
            val amount = _fastSkipAmount.value
            stepBy(if (forward) amount else -amount)
            return
        }
        scope.launch {
            var i = _currentIndex.value
            while (true) {
                val next = i + if (forward) 1 else -1
                if (next < 0 || next >= frameCount) { if (i != _currentIndex.value) setCurrentIndex(i); break }
                var c = runCatching { frames.info(sessionId, next) }.getOrNull()
                if (c != null && !c.outliersLoaded) {
                    // The counts of a frame whose outliers are still on disk are not "none", they are unknown:
                    // load them (listing does) rather than skip a frame that may have what is being looked for.
                    outliers.list(sessionId, next)
                    c = runCatching { frames.info(sessionId, next) }.getOrNull()
                }
                val skip = c != null && c.outliersLoaded && when (mode) {
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

    /** Play forward, or stop (macOS play button: it sets the direction to forward, then toggles). Space does this. */
    fun playForward() { _playMode.value = VideoPlayMode.FORWARD; togglePlayback() }
    fun playReverse() { _playMode.value = VideoPlayMode.REVERSE; togglePlayback() }

    /** Play from where it is going forward, and do nothing if already playing: never stops it (macOS `playFinalFrames`). */
    fun startPlaybackForward() {
        _playMode.value = VideoPlayMode.FORWARD
        startPlayback()
    }

    /** The mode to go back to when playback stops (macOS `previousInteractionMode`). */
    private var modeBeforePlayback: InteractionMode? = null

    fun startPlayback() {
        if (_isPlaying.value || frameCount <= 1) return
        _isPlaying.value = true
        // Editing is not possible while playing: macOS forces scrub (and a black background), and puts the
        // mode back when it stops.
        modeBeforePlayback = _mode.value
        _mode.value = InteractionMode.SCRUB
        prefetchAhead(_currentIndex.value, playbackStep(), PLAYBACK_LOOKAHEAD + 1)
        playbackJob = scope.launch {
            while (isActive && _isPlaying.value) {
                val started = System.nanoTime()
                val next = _currentIndex.value + playbackStep()
                if (next < 0 || next >= frameCount) {        // stop at the boundary; no wrap
                    setCurrentIndex(if (next < 0) 0 else frameCount - 1)
                    stopPlayback()
                    break
                }
                setCurrentIndex(next)
                prefetchAhead(next + playbackStep() * (PLAYBACK_LOOKAHEAD - 1), playbackStep(), 1)
                // Sleep what is left of the frame, not the whole of it: loading and showing the frame took time
                // too, and a fixed sleep on top of that plays slower than the rate asked for.
                val spentMs = (System.nanoTime() - started) / 1_000_000
                delay(frameDelayMs(_playbackFps.value, spentMs))
            }
        }
    }

    private fun playbackStep(): Int = if (_playMode.value == VideoPlayMode.REVERSE) -1 else 1

    fun stopPlayback() {
        _isPlaying.value = false
        playbackJob?.cancel()
        playbackJob = null
        // Back to what it was before playing, e.g. editing.
        modeBeforePlayback?.let { _mode.value = it }
        modeBeforePlayback = null
    }

    /**
     * Preview path for [index] in exactly [mode]; null when the frame has no picture of that kind. It used to fall back through the other
     * modes, so a frame that was not processed showed its original under "final"; the macOS gui shows "image not found" there (Q1).
     */
    suspend fun previewRefPath(
        index: Int, mode: FrameViewMode = FrameViewMode.VIEW_ORIGINAL,
        size: com.star.proto.PreviewSize = com.star.proto.PreviewSize.PREVIEW_SIZE_PREVIEW,
    ): String? {
        val ref = frames.previewPath(sessionId, index, mode, size)
        if (ref == null) Log.d("Sequence") { "previewRefPath(frame=$index): no $mode picture" }
        return ref?.path
    }

    /**
     * A small picture of frame [index]; the daemon's thumbnail size when [thumbnail] (the filmstrip's cells are about a hundred pixels
     * wide, and a full preview of each is many times the bytes), else the preview.
     */
    suspend fun loadThumb(index: Int, mode: FrameViewMode = FrameViewMode.VIEW_ORIGINAL, thumbnail: Boolean = false): ImageBitmap? =
        previewRefPath(index, mode, if (thumbnail) com.star.proto.PreviewSize.PREVIEW_SIZE_THUMBNAIL else com.star.proto.PreviewSize.PREVIEW_SIZE_PREVIEW)
            ?.let { imageCache.load(it, index) }

    /** Per-frame status/counts/clean-method for the grid header & right panel (`Frame.Get`). */
    suspend fun frameInfo(index: Int): com.star.proto.FrameInfo? =
        runCatching { frames.info(sessionId, index) }.getOrNull()

    /** End this session's UI: stop playback and the progress subscription, and cancel every coroutine it launched. */
    fun close() {
        stopPlayback()
        processing.stop()
        scope.cancel()
    }

    private suspend fun loadPreview(index: Int, mode: FrameViewMode) {
        previewJob?.cancel()
        previewJob = scope.launch {
            // Exactly the mode asked for. An aligned one the frame builds from its homographies is built by the daemon first (the request
            // waits, and the picture on screen stays until it is done); any other that is missing is the placeholder's "image not found".
            val ref = frames.previewPath(sessionId, index, mode, buildIfMissing = true)
            if (ref == null) {
                Log.d("Sequence") { "loadPreview(frame=$index, want=$mode): no preview available" }
                _previewAvailable.value = false
                _currentPreview.value = null
                return@launch
            }
            val bmp = imageCache.load(ref.path, index)
            Log.d("Sequence") { "loadPreview(frame=$index, want=$mode): ${ref.path} (decoded=${bmp != null})" }
            if (_currentIndex.value == index) {
                _currentPreview.value = bmp
                _previewAvailable.value = bmp != null
            }
        }
    }

    companion object {
        /** A scrub that has not moved for this long (milliseconds) has stopped: that frame is the one the extractor is asked for. */
        private const val PRIORITIZE_DEBOUNCE_MS = 80L

        /** How many frames either side of the one on screen are asked for as its neighbourhood. */
        private const val PRIORITIZE_REACH = 24

        /** How often at most the alignment results are fetched again while they are showing and the frames are changing. */
        private const val ALIGNMENT_REFRESH_MS = 1000L

        /** Outlier groups smaller than this (pixels) are left to the trash threshold, not classified (macOS `minimumClassificationSize`). */
        const val MINIMUM_CLASSIFICATION_SIZE = 20

        /** Where the outlier table's chosen columns are kept in the user preferences. */
        private const val OUTLIER_COLUMNS_KEY = "outlierTableColumns"

        /** The view counts as zoomed in once it is this much past fit. */
        private const val ZOOMED_IN = 1.01f

        /** The outlier arrows are `width / this` long (macOS `outlierArrowLength`); the view keeps room for them around the frame. */
        const val ARROW_LENGTH_DIVISOR = 70f

        /** ...and `width / this` across (macOS `outlierArrowHeight`). */
        const val ARROW_HEIGHT_DIVISOR = 180f

        /** How many frames either side of the current one keep their hit-testing label map. */
        const val LABEL_RETENTION = 2


        /** How many frames ahead of the one showing playback keeps loaded (macOS `videoPrefetchLookahead`). */
        const val PLAYBACK_LOOKAHEAD = 30
    }

    /**
     * Load [count] frames' pictures into the cache, starting at [from] and moving in [direction] (+1 forward, -1
     * reverse), in the view that is showing, so that playback finds them there instead of waiting on the disk.
     */
    private fun prefetchAhead(from: Int, direction: Int, count: Int) {
        val mode = _viewMode.value
        scope.launch {
            for (n in 0 until count) {
                val i = from + direction * n
                if (i in 0 until frameCount) previewRefPath(i, mode)?.let { imageCache.load(it, i) }
            }
        }
    }
}

/**
 * How long to wait before the next frame of a playback at [fps], given that [spentMs] of the frame's time is already
 * gone (macOS sleeps `interval - elapsed`); never negative, so a frame that was slower than its slot is followed at
 * once by the next.
 */
internal fun frameDelayMs(fps: Int, spentMs: Long): Long = ((1000L / fps.coerceAtLeast(1)) - spentMs).coerceAtLeast(0L)
