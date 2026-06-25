package com.star.desktop.ui.app

import com.star.desktop.data.FrameRepository
import com.star.desktop.data.ImageCache
import com.star.desktop.data.LocalPreferences
import com.star.desktop.data.OutlierRepository
import com.star.desktop.data.ProcessingRepository
import com.star.desktop.data.SessionRepository
import com.star.desktop.domain.InteractionMode
import com.star.desktop.engine.EngineState
import com.star.desktop.engine.EngineStatus
import com.star.desktop.ui.sequence.SequenceViewModel
import com.star.desktop.util.Log
import com.star.proto.CleanMethod
import com.star.proto.OpenProgress
import com.star.proto.SessionInfo
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch

/** What the root window is showing. */
sealed interface AppScreen {
    data object Initial : AppScreen
    data class Loading(val title: String, val detail: String?, val fraction: Float?) : AppScreen
    data class Sequence(val vm: SequenceViewModel) : AppScreen
}

/**
 * The new-source startup prompt flow (macOS `StartupView` / `StartupState`). Walked when a fresh
 * image sequence or video is opened: horizon? → camera moving? → (paint horizon yourself?) → what
 * to remove? Resuming a saved session (`OpenConfig`) skips it.
 */
enum class StartupStep { HORIZON, MOVING, SELECT_HORIZON, REMOVAL }

/**
 * Root app state (macOS `ViewModel`): owns the engine, repositories, prefs, and the current screen.
 * Engine status is collected in its own coroutine; opening a source routes Initial → Loading →
 * Sequence; engine death while a session is open surfaces an error and returns to Initial.
 */
class AppViewModel(
    private val scope: CoroutineScope,
    autoOpenPath: String? = null,
    private val autoMode: String? = null, // dev hook: "edit"/"scrub"/"grid" to land in a mode after auto-open
    private val autoFrame: Int? = null,   // dev hook: start at this frame index after auto-open
) {

    val engine = EngineState(scope)
    val prefs = LocalPreferences()
    val imageCache = ImageCache()
    val sessions = SessionRepository { engine.client }

    // Stateless wrappers shared across sessions; ProcessingRepository is per-session (holds folded state).
    private val frameRepo = FrameRepository { engine.client }
    private val outlierRepo = OutlierRepository { engine.client }
    val alignmentRepo = com.star.desktop.data.AlignmentRepository { engine.client }
    val horizonRepo = com.star.desktop.data.HorizonRepository { engine.client }

    private var currentSequence: SequenceViewModel? = null

    val engineStatus: StateFlow<EngineStatus> = engine.status

    private val _screen = MutableStateFlow<AppScreen>(AppScreen.Initial)
    val screen: StateFlow<AppScreen> = _screen.asStateFlow()

    private val _error = MutableStateFlow<String?>(null)
    val error: StateFlow<String?> = _error.asStateFlow()

    // Crash recovery: when the engine dies mid-session we offer Restart (re-opens via OpenConfig).
    private val _engineDown = MutableStateFlow<String?>(null)
    val engineDown: StateFlow<String?> = _engineDown.asStateFlow()
    private var lastResumePath: String? = null   // config.json of the open session, for re-open after restart
    private var restarting = false

    private val _recentFiles = MutableStateFlow(prefs.recentFiles)
    val recentFiles: StateFlow<List<String>> = _recentFiles.asStateFlow()

    val export = com.star.desktop.data.ExportRepository { engine.client }

    private val _showSettings = MutableStateFlow(false)
    val showSettings: StateFlow<Boolean> = _showSettings.asStateFlow()
    fun openSettings() { _showSettings.value = true }
    fun closeSettings() { _showSettings.value = false }

    private val _showRenderVideo = MutableStateFlow(false)
    val showRenderVideo: StateFlow<Boolean> = _showRenderVideo.asStateFlow()
    private val _renderVideoAutoStart = MutableStateFlow(false)
    val renderVideoAutoStart: StateFlow<Boolean> = _renderVideoAutoStart.asStateFlow()
    fun openRenderVideo(autoStart: Boolean = false) { _renderVideoAutoStart.value = autoStart; _showRenderVideo.value = true }
    fun closeRenderVideo() { _showRenderVideo.value = false; _renderVideoAutoStart.value = false }

    // ---- process → render prompt flow (macOS Pre/PostProcessingRenderPrompt) ----
    private val _showPreRenderPrompt = MutableStateFlow(false)
    val showPreRenderPrompt: StateFlow<Boolean> = _showPreRenderPrompt.asStateFlow()
    private val _showPostRenderPrompt = MutableStateFlow(false)
    val showPostRenderPrompt: StateFlow<Boolean> = _showPostRenderPrompt.asStateFlow()
    private var autoRenderAfterProcessing = false
    private var awaitingProcessingPrompt = false

    /** Entry point for "Process All": skip-pref → start directly; otherwise show the pre-render prompt. */
    fun requestProcessAll() {
        val svm = currentSequence ?: return
        if (prefs.skipRenderPromptAfterProcessing) {
            autoRenderAfterProcessing = false
            awaitingProcessingPrompt = false
            svm.processAll()
        } else {
            _showPreRenderPrompt.value = true
        }
    }

    fun confirmStartProcessing(autoRender: Boolean, dontAskAgain: Boolean) {
        if (dontAskAgain) prefs.setSkipRenderPrompt(true)
        autoRenderAfterProcessing = autoRender
        awaitingProcessingPrompt = !dontAskAgain
        _showPreRenderPrompt.value = false
        currentSequence?.processAll()
    }

    fun dismissPreRenderPrompt() { _showPreRenderPrompt.value = false }
    fun dismissPostRenderPrompt() { _showPostRenderPrompt.value = false }

    /** Post-prompt "Preview first": play the final frames from the start. */
    fun previewFinalFrames() {
        _showPostRenderPrompt.value = false
        currentSequence?.let {
            it.setViewMode(com.star.proto.FrameViewMode.VIEW_PROCESSED)
            it.goToFirst()
            it.playForward()
        }
    }

    fun confirmRenderAfterProcessing() {
        _showPostRenderPrompt.value = false
        openRenderVideo(autoStart = true)
    }

    private fun handleProcessingDone() {
        if (!awaitingProcessingPrompt) return
        awaitingProcessingPrompt = false
        if (autoRenderAfterProcessing) {
            autoRenderAfterProcessing = false
            openRenderVideo(autoStart = true)
        } else {
            _showPostRenderPrompt.value = true
        }
    }

    private val _showOutlierWindow = MutableStateFlow(false)
    val showOutlierWindow: StateFlow<Boolean> = _showOutlierWindow.asStateFlow()
    fun toggleOutlierWindow() { _showOutlierWindow.value = !_showOutlierWindow.value }
    fun closeOutlierWindow() { _showOutlierWindow.value = false }

    private val _showAlignmentWindow = MutableStateFlow(false)
    val showAlignmentWindow: StateFlow<Boolean> = _showAlignmentWindow.asStateFlow()
    fun toggleAlignmentWindow() { _showAlignmentWindow.value = !_showAlignmentWindow.value }
    fun closeAlignmentWindow() { _showAlignmentWindow.value = false }

    private val _showInfoDialog = MutableStateFlow(false)
    val showInfoDialog: StateFlow<Boolean> = _showInfoDialog.asStateFlow()
    fun openInfoDialog() { _showInfoDialog.value = true }
    fun closeInfoDialog() { _showInfoDialog.value = false }

    // §4.4: non-blocking warning when a resumed session's config.starVersion ≠ the running engine.
    private val _versionWarning = MutableStateFlow<String?>(null)
    val versionWarning: StateFlow<String?> = _versionWarning.asStateFlow()
    fun dismissVersionWarning() { _versionWarning.value = null }

    // ---- new-source startup prompts (macOS StartupView) ----
    private val _startupStep = MutableStateFlow<StartupStep?>(null) // null = not showing
    val startupStep: StateFlow<StartupStep?> = _startupStep.asStateFlow()
    // Accumulated answers, applied to the session config when the user opens Advanced or starts processing.
    private var startupHasHorizon = false
    private var startupCameraMoving = false
    private var startupAllowEarth = false

    private fun resetStartupChoices() {
        startupHasHorizon = false
        startupCameraMoving = false
        startupAllowEarth = false
    }

    /** Prompt 1 answer: does the sequence include a horizon? */
    fun startupAnswerHorizon(hasHorizon: Boolean) {
        startupHasHorizon = hasHorizon
        _startupStep.value = StartupStep.MOVING
    }

    /** Prompt 2 answer: was the camera moving (false = static on a tripod)? */
    fun startupAnswerMoving(moving: Boolean) {
        startupCameraMoving = moving
        startupAllowEarth = !moving // macOS defaults earth alignment on for static cameras
        _startupStep.value = if (startupHasHorizon) StartupStep.SELECT_HORIZON else StartupStep.REMOVAL
    }

    /** Prompt 3 answer: paint the horizon yourself? Yes → open the horizon painter; No → removal. */
    fun startupAnswerSelectHorizon(selectYourself: Boolean) {
        if (selectYourself) {
            scope.launch { applyStartupChoices() }
            _startupStep.value = null
            currentSequence?.let {
                it.setMode(InteractionMode.EDIT)
                if (!it.horizonPaintMode.value) it.toggleHorizonPaint()
            }
        } else {
            _startupStep.value = StartupStep.REMOVAL
        }
    }

    /** "Advanced" gear on a prompt: persist the answers so the dialog reflects them, then open settings. */
    fun startupOpenAdvanced() {
        scope.launch {
            applyStartupChoices()
            _startupStep.value = null
            openSettings()
        }
    }

    /** Removal prompt "Start Processing": apply the chosen clean method + answers, then process. */
    fun startupStartProcessing(cleanMethod: CleanMethod) {
        scope.launch {
            applyStartupChoices(cleanMethod)
            _startupStep.value = null
            requestProcessAll()
        }
    }

    /** Removal prompt "Close": dismiss the prompts without processing (keeps the default config). */
    fun dismissStartup() { _startupStep.value = null }

    /** Fold the accumulated startup answers (and optionally a clean method) into the live session config. */
    private suspend fun applyStartupChoices(cleanMethod: CleanMethod? = null) {
        val current = runCatching { sessions.getConfig() }.getOrNull() ?: return
        val b = current.toBuilder()
            .setHorizonDetectionEnabled(startupHasHorizon)
            .setTripodHeadWasMoving(startupCameraMoving)
            .setAllowEarthAlignment(startupAllowEarth)
        cleanMethod?.let { b.setCleanMethod(it) }
        runCatching { sessions.updateConfig(b.build()) }
    }

    init {
        scope.launch { engine.start() }
        scope.launch {
            engine.status.collect { st ->
                // Engine died while a session was open: offer Restart (don't tear the session down yet —
                // restart re-opens it via OpenConfig). A deliberate restart() sets `restarting` to suppress this.
                if (st is EngineStatus.Failed && _screen.value is AppScreen.Sequence && !restarting) {
                    _engineDown.value = st.message
                }
            }
        }
        if (autoOpenPath != null) {
            when (com.star.desktop.ui.initial.inferOpenKind(autoOpenPath)) {
                com.star.desktop.ui.initial.OpenKind.SEQUENCE -> openSequence(autoOpenPath)
                com.star.desktop.ui.initial.OpenKind.VIDEO -> openVideo(autoOpenPath)
                com.star.desktop.ui.initial.OpenKind.CONFIG -> openConfig(autoOpenPath)
            }
        }
    }

    fun openSequence(dir: String) = launchOpen("Opening image sequence", dir, promptStartup = true) { sessions.openSequence(dir) }

    fun openConfig(path: String) = launchOpen("Resuming session", path) { sessions.openConfig(path) }

    fun openVideo(path: String) {
        scope.launch {
            ensureConnected()
            _screen.value = AppScreen.Loading("Importing video", path, null)
            try {
                var info: SessionInfo? = null
                sessions.openVideo(path).collect { p ->
                    when (p.kindCase) {
                        OpenProgress.KindCase.PROGRESS -> {
                            val io = p.progress
                            val frac = if (io.total > 0) io.current.toFloat() / io.total else null
                            _screen.value = AppScreen.Loading("Importing video", "${io.current} / ${io.total}", frac)
                        }
                        OpenProgress.KindCase.DONE -> info = p.done
                        else -> Unit
                    }
                }
                val finalInfo = info
                if (finalInfo != null) {
                    sessions.applySessionInfo(finalInfo)
                    onOpened(path, finalInfo, promptStartup = true)
                } else {
                    fail("video import produced no session")
                }
            } catch (e: Throwable) {
                fail(e.message ?: "failed to import video")
            }
        }
    }

    fun closeSession() {
        scope.launch {
            currentSequence?.close()
            currentSequence = null
            runCatching { sessions.close() }
            _screen.value = AppScreen.Initial
        }
    }

    fun dismissError() { _error.value = null }

    /** Restart a crashed engine and re-open the last session from its config.json (§2.1 crash recovery). */
    fun restartEngine() {
        val resume = lastResumePath
        scope.launch {
            restarting = true
            _engineDown.value = null
            _screen.value = AppScreen.Loading("Restarting engine", null, null)
            val ok = engine.restart()
            restarting = false
            if (!ok) { fail("Failed to restart the engine"); return@launch }
            if (resume != null && java.io.File(resume).exists()) {
                _screen.value = AppScreen.Loading("Resuming session", resume, null)
                try {
                    onOpened(resume, sessions.openConfig(resume), addToRecent = false)
                } catch (e: Throwable) {
                    fail(e.message ?: "failed to resume session after restart")
                }
            } else {
                _screen.value = AppScreen.Initial
            }
        }
    }

    /** Give up on a crashed engine: close the dead session and return to the start screen. */
    fun dismissEngineDown() {
        _engineDown.value = null
        currentSequence?.close()
        currentSequence = null
        runCatching { sessions.clearLocal() }
        _screen.value = AppScreen.Initial
    }

    fun removeRecent(path: String) {
        prefs.removeRecentFile(path)
        _recentFiles.value = prefs.recentFiles
    }

    suspend fun shutdown() = engine.shutdown()

    private fun launchOpen(title: String, path: String, promptStartup: Boolean = false, block: suspend () -> SessionInfo) {
        scope.launch {
            ensureConnected()
            _screen.value = AppScreen.Loading(title, path, null)
            try {
                onOpened(path, block(), promptStartup = promptStartup)
            } catch (e: Throwable) {
                fail(e.message ?: "failed to open")
            }
        }
    }

    private fun onOpened(path: String, info: SessionInfo, addToRecent: Boolean = true, promptStartup: Boolean = false) {
        if (addToRecent) {
            prefs.addRecentFile(path)
            _recentFiles.value = prefs.recentFiles
        }
        // The session's on-disk config.json — the resume path for crash recovery (cross-client resume).
        lastResumePath = "${info.scratchSessionDir}/config.json"
        _engineDown.value = null
        // Warn if the session was last written by a different engine version (req #4).
        val engineVer = (engine.status.value as? EngineStatus.Connected)?.daemonVersion
        _versionWarning.value = com.star.desktop.util.versionMismatchWarning(info.config.starVersion, engineVer)
        currentSequence?.close()
        val proc = ProcessingRepository(scope) { engine.client }
        // Fire the post-processing render prompt when a prompted process-all run reaches "done".
        scope.launch { proc.sequenceState.collect { if (it == "done") handleProcessingDone() } }
        val svm = SequenceViewModel(scope, info, frameRepo, proc, outlierRepo, imageCache, export, horizonRepo)
        when (autoMode) {
            "edit" -> svm.setMode(com.star.desktop.domain.InteractionMode.EDIT)
            "grid" -> svm.setMode(com.star.desktop.domain.InteractionMode.GRID)
            "align" -> toggleAlignmentWindow()
            "horizon" -> { svm.setMode(com.star.desktop.domain.InteractionMode.EDIT); svm.toggleHorizonPaint() }
            "info" -> openInfoDialog()                  // dev hook: screenshot the Info dialog
            "prerender" -> _showPreRenderPrompt.value = true   // dev hook: screenshot the pre-render prompt
            "postrender" -> _showPostRenderPrompt.value = true // dev hook: screenshot the post-render prompt
            "multiselect" -> svm.openMultiSelect(SequenceViewModel.RectSelection(100f, 100f, 400f, 400f)) // dev hook
            "settings" -> openSettings() // dev hook: screenshot the Processing Settings dialog
            "startup" -> { resetStartupChoices(); _startupStep.value = StartupStep.HORIZON } // dev hook: startup prompts
            else -> Unit
        }
        autoFrame?.let { svm.setCurrentIndex(it) }
        currentSequence = svm
        _screen.value = AppScreen.Sequence(svm)
        // Fresh source → walk the startup prompts (skipped for config resume + dev auto-open hooks).
        if (promptStartup && autoMode == null) {
            resetStartupChoices()
            _startupStep.value = StartupStep.HORIZON
        }
    }

    private fun fail(message: String) {
        Log.w("App") { message }
        _error.value = message
        _screen.value = AppScreen.Initial
    }

    private suspend fun ensureConnected() {
        if (engine.client != null) return
        engine.start()
        // Wait until the handshake resolves; otherwise an immediate open (e.g. auto-open or a fast
        // click) races the connection and fails with "engine not connected".
        engine.status.first { it is EngineStatus.Connected || it is EngineStatus.Failed }
    }
}
