package com.star.desktop.ui.app

import com.star.desktop.data.FrameRepository
import com.star.desktop.data.ImageCache
import com.star.desktop.data.LocalPreferences
import com.star.desktop.i18n.Strings
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
 *
 * `SELECT_HORIZON` is the static (single-horizon) variant; `SELECT_MOVING_HORIZONS` is the moving
 * variant where the user picks how many evenly-spaced frames to paint.
 */
enum class StartupStep { HORIZON, MOVING, SELECT_HORIZON, SELECT_MOVING_HORIZONS, REMOVAL }

/**
 * Evenly-spaced frame indices for [count] horizons over [total] frames (macOS
 * `ImageSequenceViewModel.calculateFrameIndices`): `count == 1` → `[0]`; `count >= total` → every
 * frame; otherwise `round(i * (total - 1) / (count - 1))` so the first is frame 0, the last is
 * `total - 1`, and the rest are spread evenly between.
 */
internal fun evenlySpacedFrameIndices(count: Int, total: Int): List<Int> {
    if (count <= 0 || total <= 0) return emptyList()
    if (count == 1) return listOf(0)
    if (count >= total) return (0 until total).toList()
    return (0 until count).map { i -> Math.round(i.toDouble() * (total - 1) / (count - 1)).toInt() }
}

/**
 * How many reference horizons to suggest painting for a moving sequence of [total] frames (macOS
 * `ImageSequenceViewModel.suggestedMovingHorizonCount`). A moving camera drifts further over a
 * longer sequence, so `sqrt(total / 10)` tracks the length while growing slowly enough to stay
 * reasonable: 12 for the 1450 frame sequence 12 was measured to work well on, 14 at 2000, 22 at
 * 5000. The floor of 3 keeps the old fixed suggestion for anything under about 120 frames.
 */
internal fun suggestedMovingHorizonCount(total: Int): Int {
    if (total <= 0) return 1
    val scaled = Math.round(Math.sqrt(total.toDouble() / 10)).toInt()
    return minOf(maxOf(3, scaled), total)
}

/**
 * [suggestedMovingHorizonCount] bent by what the user picked last time, as recorded in
 * `LocalPreferences.movingHorizonCountMultiplier` (macOS `preferredMovingHorizonCount`). A null
 * multiplier — the user has never moved the stepper — leaves the suggestion alone.
 *
 * The baseline's floor of 3 deliberately does not apply here: a user who asked for fewer
 * references than star suggests gets fewer, down to one.
 */
internal fun preferredMovingHorizonCount(total: Int, multiplier: Double?): Int {
    val baseline = suggestedMovingHorizonCount(total)
    if (multiplier == null || multiplier <= 0 || !multiplier.isFinite()) return baseline
    val ceiling = maxOf(1, total)
    // compared as a Long before narrowing: a hand-edited multiplier can scale past Int range
    val scaled = Math.round(baseline * multiplier)
    if (scaled >= ceiling) return ceiling
    return maxOf(1, scaled.toInt())
}

/**
 * What to record when the user picks [chosen] horizons for a sequence of [total] frames: how their
 * choice compares to what star suggested for that length (macOS `movingHorizonCountMultiplier`).
 *
 * Deliberately unclamped — clamping would mean re-opening that same sequence offered a different
 * number than the one the user chose.
 */
internal fun movingHorizonCountMultiplier(chosen: Int, total: Int): Double =
    chosen.toDouble() / suggestedMovingHorizonCount(total)

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

    init {
        // Before any window is composed, so the first frame the user sees is already in their
        // language rather than flashing English. Also before the engine connects, so the
        // locale sent on Daemon.Hello is the one the UI is actually showing.
        Strings.setOverride(prefs.language)
    }

    /** Every language the Language menu offers. */
    val availableLanguages get() = Strings.languages

    /** Switch languages, and remember it. `null` goes back to following the system. */
    fun setLanguage(code: String?) {
        prefs.setLanguage(code)
        Strings.setOverride(code)
    }
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

    // ---- engine warnings pushed by the daemon ----
    //
    // Memory pressure, output it could not write, a disk with no room. Before the daemon could
    // push these they went only to its stderr, which this client drains into a sink that in a
    // packaged app goes nowhere a user can read — so a run walking into an out-of-memory kill
    // looked completely normal right up until the engine died.
    private val _engineWarning = MutableStateFlow<com.star.proto.Warning?>(null)
    val engineWarning: StateFlow<com.star.proto.Warning?> = _engineWarning.asStateFlow()
    fun dismissEngineWarning() { _engineWarning.value = null }

    // ---- new-source startup prompts (macOS StartupView) ----
    private val _startupStep = MutableStateFlow<StartupStep?>(null) // null = not showing
    val startupStep: StateFlow<StartupStep?> = _startupStep.asStateFlow()
    // Accumulated answers, applied to the session config when the user opens Advanced or starts processing.
    private var startupHasHorizon = false
    private var startupCameraMoving = false

    private fun resetStartupChoices() {
        startupHasHorizon = false
        startupCameraMoving = false
    }

    /** Prompt 1 answer: does the sequence include a horizon? */
    fun startupAnswerHorizon(hasHorizon: Boolean) {
        startupHasHorizon = hasHorizon
        _startupStep.value = StartupStep.MOVING
    }

    /** Prompt 2 answer: was the camera moving (false = static on a tripod)? */
    fun startupAnswerMoving(moving: Boolean) {
        startupCameraMoving = moving
        _startupStep.value = when {
            !startupHasHorizon -> StartupStep.REMOVAL
            moving -> StartupStep.SELECT_MOVING_HORIZONS
            else -> StartupStep.SELECT_HORIZON
        }
    }

    /**
     * Prompt 3 (static) answer: paint the horizon yourself? Yes → open the painter on the current
     * frame in startup mode (single horizon); No → removal. (macOS `SelectHorizonView`.)
     */
    fun startupAnswerSelectHorizon(selectYourself: Boolean) {
        if (selectYourself) startStaticHorizonStartupFlow()
        else _startupStep.value = StartupStep.REMOVAL
    }

    /**
     * Prompt 3 (moving) "Yes, select N horizons": open the painter in startup mode and step through
     * [count] evenly-spaced frames (macOS `startMovingHorizonStartupFlow`). "No" goes to removal via
     * [startupAnswerSelectHorizon].
     */
    fun startMovingHorizonStartupFlow(count: Int) {
        val svm = currentSequence ?: return
        scope.launch {
            applyStartupChoices() // persist moving/horizon to config before saving per-frame references
            svm.beginStartupHorizon(evenlySpacedFrameIndices(count, svm.frameCount))
            _startupStep.value = null
        }
    }

    /** Static SelectHorizon "Yes": paint the single current frame in startup mode. */
    private fun startStaticHorizonStartupFlow() {
        val svm = currentSequence ?: return
        scope.launch {
            applyStartupChoices()
            svm.beginStartupHorizon(emptyList()) // empty = single frame (the one currently shown)
            _startupStep.value = null
        }
    }

    /** Painter "Next"/"Continue" in startup mode: advance to the next frame, or finish → removal. */
    fun startupHorizonAdvanceOrContinue() {
        val svm = currentSequence ?: return
        if (svm.startupHorizonHasMore()) svm.advanceStartupHorizon()
        else continueToRemovalFromHorizonPainter()
    }

    /** Finish startup horizon painting → show the removal prompt (macOS `continueToRemovalFromHorizonPainter`). */
    fun continueToRemovalFromHorizonPainter() {
        currentSequence?.endStartupHorizon()
        _startupStep.value = StartupStep.REMOVAL
    }

    /** Painter "Cancel" in startup mode → back to the moving/stationary question (macOS `returnToMovingViewFromHorizonPainter`). */
    fun cancelStartupHorizon() {
        currentSequence?.endStartupHorizon()
        _startupStep.value = StartupStep.MOVING
    }

    /** Total frames in the open sequence — bounds the moving-horizon count stepper. */
    fun startupFrameCount(): Int = (currentSequence?.frameCount ?: 1).coerceAtLeast(1)

    /** The horizon count to offer for the open sequence, personalised by the stored preference. */
    fun preferredHorizonCount(): Int =
        preferredMovingHorizonCount(startupFrameCount(), prefs.movingHorizonCountMultiplier)

    /**
     * Remember that the user asked for [chosen] horizons on a sequence this long, so that a
     * sequence of a different length gets proportionally more or fewer next time. Called on every
     * step, so the preference survives even if the user abandons the prompt afterwards.
     */
    fun recordHorizonCount(chosen: Int) {
        prefs.setMovingHorizonCountMultiplier(movingHorizonCountMultiplier(chosen, startupFrameCount()))
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
            // Earth alignment is on for both static and moving sequences now that the
            // ground homography guard rejects the warps it used to apply blindly.
            .setAllowEarthAlignment(true)
        cleanMethod?.let { b.setCleanMethod(it) }
        runCatching { sessions.updateConfig(b.build()) }
    }

    init {
        scope.launch { engine.start() }
        scope.launch {
            // Latest wins: these describe the machine's current state, so an older one being
            // replaced by a newer is right. The user can dismiss, and the next one re-raises.
            engine.warnings.collect { _engineWarning.value = it }
        }
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
