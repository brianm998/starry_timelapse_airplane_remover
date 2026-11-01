package com.star.desktop.ui.app

import com.star.desktop.data.FrameRepository
import com.star.desktop.data.ImageCache
import com.star.desktop.data.LocalPreferences
import com.star.desktop.i18n.Strings
import com.star.desktop.i18n.localized
import com.star.desktop.data.OutlierRepository
import com.star.desktop.data.ProcessingRepository
import com.star.desktop.data.SessionRepository
import com.star.desktop.domain.CloseAction
import com.star.desktop.domain.CloseConfirmation
import com.star.desktop.domain.GpuToggle
import com.star.desktop.domain.InteractionMode
import com.star.desktop.domain.PendingWork
import com.star.desktop.engine.EngineState
import com.star.desktop.domain.RenderState
import com.star.desktop.domain.RenderVideo
import com.star.desktop.domain.WarningRouting
import com.star.desktop.domain.WarningState
import com.star.desktop.domain.isRendering
import com.star.desktop.engine.EngineStatus
import com.star.desktop.ui.sequence.SequenceViewModel
import com.star.desktop.util.Log
import com.star.proto.CleanMethod
import com.star.proto.Config
import com.star.proto.OpenProgress
import com.star.proto.ProgressEvent
import com.star.proto.SequenceProgress
import com.star.proto.SessionInfo
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.coroutines.withContext

/** How long quitting waits for the engine to shut down before it goes without it. */
private const val QUIT_WAIT_MS = 5_000L

/** What the root window is showing. */
sealed interface AppScreen {
    data object Initial : AppScreen
    /** A wait with a title ([titleKey] is a catalogue key, so the title follows the language) and, if there is one, what it is on. */
    data class Loading(val titleKey: String, val detail: String?, val fraction: Float?) : AppScreen

    /** A source is being opened, with the Cancel that stops it (macOS `ImageSequenceLoadingView`). */
    data class Opening(val progress: com.star.desktop.domain.LoadingProgress) : AppScreen
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
 * The frame a recorded horizon selection should resume on, or null when there is nothing to
 * resume (macOS `ImageSequenceViewModel.startupHorizonResumeFrame`).
 *
 * Null for a selection that was never started (empty list) or that ran to the end — the list is
 * cleared then, so a position past it means the two halves of the record disagree — and for a
 * frame the sequence does not have. That last one is not paranoia for its own sake: config.json
 * can be hand edited, and a sequence can be re-extracted at a different length while its config
 * survives.
 */
internal fun startupHorizonResumeFrame(indices: List<Int>, position: Int, frameCount: Int): Int? {
    if (position < 0 || position >= indices.size) return null
    val frameIndex = indices[position]
    if (frameIndex < 0 || frameIndex >= frameCount) return null
    return frameIndex
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
 * Where the startup flow goes after "was the camera moving?": straight to the removal question when the
 * sequence has no horizon, otherwise to choosing horizons, one for a static camera and several for a moving
 * one (macOS `MovingView`).
 */
internal fun stepAfterCameraMotion(hasHorizon: Boolean, moving: Boolean): StartupStep = when {
    !hasHorizon -> StartupStep.REMOVAL
    moving -> StartupStep.SELECT_MOVING_HORIZONS
    else -> StartupStep.SELECT_HORIZON
}

/**
 * Which question screen "Back" returns to from [step], derived from the answers already given rather than a
 * separate history stack, since they fully determine how [step] was reached (macOS
 * `RemovalView.previousStartupState`). null on the first screen.
 *
 * The answers are the session config's, whoever gave them: a session resumed part way through the startup flow
 * has them from the config too, which a private copy in the view model never had.
 */
internal fun previousStartupStep(step: StartupStep, hasHorizon: Boolean, moving: Boolean): StartupStep? = when (step) {
    StartupStep.HORIZON -> null
    StartupStep.MOVING -> StartupStep.HORIZON
    StartupStep.SELECT_HORIZON -> StartupStep.MOVING
    StartupStep.SELECT_MOVING_HORIZONS -> StartupStep.MOVING
    StartupStep.REMOVAL -> if (!hasHorizon) StartupStep.MOVING else if (moving) StartupStep.SELECT_MOVING_HORIZONS else StartupStep.SELECT_HORIZON
}

/**
 * [current] with what the removal question decides: the clean method (when one was chosen) and whether earth
 * alignment is allowed. Nothing else: whether there is a horizon and whether the camera moved were written
 * into the config as they were answered, and are the config's to say, not this call's to overwrite.
 */
internal fun withRemovalChoices(current: Config, cleanMethod: CleanMethod?, allowEarthAlignment: Boolean): Config {
    val b = current.toBuilder().setAllowEarthAlignment(allowEarthAlignment)
    cleanMethod?.let { b.setCleanMethod(it) }
    return b.build()
}

/**
 * The initial config for opening [source] (an image sequence's folder or a video file): StarCore's default clean
 * method (automatic), previews on, and output written into the folder that holds the source, never left to the daemon's
 * per-session scratch fallback (a fresh hidden temp dir on every open). Config's `basename` already embeds
 * the sequence's own dirname, so this can't collide with a sibling sequence, and opening the same source
 * again resolves to the same output location, which is what lets `FrameAirplaneRemover.init`'s
 * `outputFileExistsOnDisk()` check find a previous run's output and report finished frames as complete
 * instead of unprocessed (macOS `inputImageSequencePath`).
 */
internal fun initialConfigBeside(source: String, detection: com.star.proto.DetectionType? = null, outputDir: String? = null): Config =
    SessionRepository.defaultInitialConfig().toBuilder()
        .setOutputPath(outputDir ?: java.io.File(source).parent ?: source)
        .also { b -> detection?.let { b.setDetectionType(it) } }
        .build()

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
    /** Whether there is a release newer than the version running (macOS checks GitHub at launch); replaced by tests. */
    private val releaseCheck: suspend (running: String) -> com.star.desktop.util.GitHubRelease? = { com.star.desktop.util.ReleaseCheck.check(it) },
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
        // The engine words its own warnings and errors: it is told, or they would stay in the language it started with.
        scope.launch { engine.announceLanguage() }
    }
    val imageCache = ImageCache()
    val sessions = SessionRepository { engine.client }

    // Stateless wrappers shared across sessions; ProcessingRepository is per-session (holds folded state).
    private val frameRepo = FrameRepository { engine.client }
    private val outlierRepo = OutlierRepository { engine.client }
    val alignmentRepo = com.star.desktop.data.AlignmentRepository { engine.client }
    val horizonRepo = com.star.desktop.data.HorizonRepository { engine.client }

    private var currentSequence: SequenceViewModel? = null

    /** What this class itself runs for the open session (the render-prompt and error collectors); cancelled when it closes. */
    private var sessionScope: CoroutineScope? = null

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

    /**
     * Apply [config] to the open session (`Sequence.UpdateConfig`), and tell what is showing if the clean method
     * changed, so frames loaded earlier do not keep reporting the old one and the tool is reset if the new method
     * has none. Throws if the daemon refuses it.
     */
    suspend fun updateSessionConfig(config: Config): Config {
        val beforeConfig = sessions.session.value?.config
        val before = beforeConfig?.cleanMethod
        val beforeDetection = beforeConfig?.detectionType
        val updated = sessions.updateConfig(config)
        // The GPU toggles are about this machine, not this sequence: what the user changed is what every sequence opened from now on starts with.
        if (beforeConfig != null) GpuToggle.changed(beforeConfig, updated).forEach { (toggle, value) -> prefs.setGpu(toggle, value) }
        if (before != null && updated.cleanMethod != before) currentSequence?.cleanMethodChanged(updated.cleanMethod)
        // The type the user picks is the one the next sequence starts from, wherever it was picked (macOS keeps it as it changes).
        if (beforeDetection != null && updated.detectionType != beforeDetection) rememberDetectionType(updated.detectionType)
        return updated
    }

    /**
     * The detection-type picker beside "re-process the next N frames" (macOS RightPanel): applied to the session, and kept as the user's
     * choice for the next one under the key the macOS app uses (`processingType`, the type's name).
     */
    fun setDetectionType(type: com.star.proto.DetectionType) {
        scope.launch {
            val current = runCatching { sessions.getConfig() }.getOrNull() ?: return@launch
            if (current.detectionType != type) {
                runCatching { updateSessionConfig(current.toBuilder().setDetectionType(type).build()) }.onFailure { report(it.message ?: it.toString()) }
            }
            rememberDetectionType(type)
        }
    }

    /** The detection type new sequences start from: the one the user last chose (macOS `userPreferences.processingType`), if they have. */
    fun savedDetectionType(): com.star.proto.DetectionType? = com.star.desktop.domain.DetectionPreference.fromPref(prefs.string(com.star.desktop.domain.DetectionPreference.KEY))

    /** Keep [type] as the user's choice for the next sequence, under the key the macOS app uses. */
    fun rememberDetectionType(type: com.star.proto.DetectionType) {
        prefs.setString(com.star.desktop.domain.DetectionPreference.KEY, com.star.desktop.domain.DetectionPreference.toPref(type))
    }

    /**
     * "Use of this Mac" (macOS ResourceProfileView): how much of the machine a run may take, `full`, `balanced`, `light` or `custom`. Applied to
     * the session at once, which reaches a run in progress (the daemon moves its limits then and there).
     */
    fun setResourceProfile(profile: String) {
        scope.launch {
            val current = runCatching { sessions.getConfig() }.getOrNull() ?: return@launch
            if (current.hasResourceProfile() && current.resourceProfile == profile) return@launch
            runCatching { updateSessionConfig(com.star.desktop.domain.ResourceProfiles.switchTo(current, profile)) }.onFailure { report(it.message ?: it.toString()) }
        }
    }

    /** The Custom limits, set as the popover edits them (macOS applies each as it changes, and a run in progress moves to it). */
    fun setCustomLimits(limits: com.star.desktop.domain.CustomLimits) {
        scope.launch {
            val current = runCatching { sessions.getConfig() }.getOrNull() ?: return@launch
            runCatching { updateSessionConfig(limits.applyTo(current)) }.onFailure { report(it.message ?: it.toString()) }
        }
    }

    // The Custom limits popover (macOS `ResourceCustomLimitsView`): up while the user is editing them.
    private val _showCustomLimits = MutableStateFlow(false)
    val showCustomLimits: StateFlow<Boolean> = _showCustomLimits.asStateFlow()
    fun openCustomLimits() { _showCustomLimits.value = true }
    fun closeCustomLimits() { _showCustomLimits.value = false }

    /**
     * What applying [config] would do to the work already on disk (the settings sheet's red line, and Process Now becoming Update); null when
     * the daemon could not say, which the sheet reads as nothing to warn about.
     */
    suspend fun previewConfigChange(config: Config): com.star.proto.ConfigChangePreview? =
        runCatching { sessions.previewConfigChange(config) }.getOrNull()

    /**
     * The answer to "re-process the already processed frames with these settings?": apply [config] with [reprocess] set as the answer, which
     * decides whether a change throws away what it invalidated and builds it again, or keeps it and applies only to the frames still to do. A
     * run that is going is restarted so that the change reaches the frames it has not got to (its graph was planned under the old settings);
     * otherwise processing starts, with the usual question about rendering after.
     */
    fun updateSettingsAndProcess(config: Config, reprocess: Boolean) {
        scope.launch {
            val running = currentSequence?.isProcessing?.value == true
            runCatching { updateSessionConfig(config.toBuilder().setReprocessOnSettingsChange(reprocess).build()) }.onFailure { report(it.message ?: it.toString()) }
            closeSettings()
            if (running) {
                // As the gui: stop, and ask the question about rendering again, since the answer given was for the run being replaced (P4).
                // With the question turned off there is nothing to ask, and the run is started over in one step.
                if (prefs.skipRenderPromptAfterProcessing) {
                    renderQuestion.disarm()
                    currentSequence?.restartProcessing()
                } else {
                    currentSequence?.cancelProcessing()
                    requestProcessAll()
                }
            } else {
                requestProcessAll()
            }
        }
    }

    // The Preferences dialog (macOS's sheet on Cmd-,); the Processing Settings it used to open are Cmd-Shift-,.
    private val _showPreferences = MutableStateFlow(false)
    val showPreferences: StateFlow<Boolean> = _showPreferences.asStateFlow()
    fun openPreferences() { _showPreferences.value = true }
    fun closePreferences() { _showPreferences.value = false }

    private val _showSettings = MutableStateFlow(false)
    val showSettings: StateFlow<Boolean> = _showSettings.asStateFlow()
    fun openSettings() { _showSettings.value = true }
    fun closeSettings() { _showSettings.value = false }

    private val _showRenderVideo = MutableStateFlow(false)
    val showRenderVideo: StateFlow<Boolean> = _showRenderVideo.asStateFlow()
    private val _renderVideoAutoStart = MutableStateFlow(false)
    val renderVideoAutoStart: StateFlow<Boolean> = _renderVideoAutoStart.asStateFlow()
    /**
     * How the automatic render is to be done, as chosen in the pre-processing prompt's options step: the dialog starts from it and not from the
     * config. null for every other render. Held from the end of the run to the render's start, or the dialog's closing.
     */
    var pendingRenderSettings: com.star.proto.VideoEncodeSettings? = null
        private set
    fun openRenderVideo(autoStart: Boolean = false, settings: com.star.proto.VideoEncodeSettings? = null) {
        pendingRenderSettings = settings
        _renderVideoAutoStart.value = autoStart
        _showRenderVideo.value = true
    }
    fun closeRenderVideo() {
        // The dialog is the only way to stop a render: closing it over one would leave ffmpeg writing a video nobody is looking at.
        if (isRendering) return
        _showRenderVideo.value = false
        _renderVideoAutoStart.value = false
        pendingRenderSettings = null
        _renderState.value = RenderState.Choosing
    }

    // ---- the render itself (macOS RenderVideoSheetView's isRendering / renderSuccess / renderingError) ----
    //
    // Held here and not in the dialog so that anything that has to know whether a render is going can ask: closing the window will.
    private val _renderState = MutableStateFlow<RenderState>(RenderState.Choosing)
    val renderState: StateFlow<RenderState> = _renderState.asStateFlow()
    private var renderJob: Job? = null

    /** Whether a video is being rendered. */
    val isRendering: Boolean get() = _renderState.value.isRendering

    /**
     * Render the video with [settings] into [fileName] (which only says what to call it in the dialog: the daemon names the file and says where it
     * put it). Ends in [RenderState.Succeeded] with where it went, or [RenderState.Failed]; cancelling ([cancelRender]) goes back to choosing, with
     * the daemon having stopped ffmpeg and removed the partial file.
     */
    fun startRender(settings: com.star.proto.VideoEncodeSettings, fileName: String) {
        val sessionId = sessions.sessionId ?: return
        if (isRendering) return
        // Said once, here: the dialog is not asked to start again by the render prompt's "Yes" after this.
        consumeRenderVideoAutoStart()
        pendingRenderSettings = null
        _renderState.value = RenderState.Rendering(fileName, 0, 0)
        renderJob = scope.launch {
            try {
                var writtenTo: String? = null
                export.exportVideo(sessionId, "", settings).collect { ev ->
                    when (ev.kindCase) {
                        ProgressEvent.KindCase.IO_PROGRESS ->
                            _renderState.value = RenderState.Rendering(fileName, ev.ioProgress.current, ev.ioProgress.total)
                        ProgressEvent.KindCase.VIDEO_EXPORTED -> writtenTo = ev.videoExported.outputVideoPath
                        else -> Unit
                    }
                }
                val path = writtenTo?.takeIf { it.isNotEmpty() }
                _renderState.value = RenderState.Succeeded(path?.let { RenderVideo.fileName(it) } ?: fileName, path)
            } catch (e: CancellationException) {
                _renderState.value = RenderState.Choosing   // the user stopped it
                throw e
            } catch (e: Throwable) {
                Log.w("App") { "render failed: ${e.message}" }
                _renderState.value = RenderState.Failed(e.message ?: e.toString())
            } finally {
                renderJob = null
            }
        }
    }

    /** Stop the render in progress. */
    fun cancelRender() { renderJob?.cancel() }

    /** The render the prompt asked for has started: the dialog must not start another when something it watches changes. */
    fun consumeRenderVideoAutoStart() { _renderVideoAutoStart.value = false }

    // ---- process → render prompt flow (macOS Pre/PostProcessingRenderPrompt) ----
    private val _showPreRenderPrompt = MutableStateFlow(false)
    val showPreRenderPrompt: StateFlow<Boolean> = _showPreRenderPrompt.asStateFlow()
    /** Which step of the pre-processing prompt is up: the question, or the render options after Yes. */
    private val preRenderFlow = PreRenderPromptFlow()
    /** [PreRenderPromptFlow.Step.CHOOSING] while the render options are up in place of the question. */
    val preRenderStep: StateFlow<PreRenderPromptFlow.Step> = preRenderFlow.step
    private val _showPostRenderPrompt = MutableStateFlow(false)
    val showPostRenderPrompt: StateFlow<Boolean> = _showPostRenderPrompt.asStateFlow()
    /** The question at the end of a run, and which run it is about (P11). */
    private val renderQuestion = RenderQuestion()

    /** Arm the end-of-run question for the run the next `processAll` (or resume) starts. */
    private fun armRenderQuestion(render: Boolean, ask: Boolean, settings: com.star.proto.VideoEncodeSettings? = null) {
        renderQuestion.arm(forRun = (currentSequence?.runsStarted ?: 0) + 1, render = render, ask = ask, settings = settings)
    }

    /** Entry point for "Process All": skip-pref → start directly; otherwise show the pre-render prompt. */
    fun requestProcessAll() {
        val svm = currentSequence ?: return
        if (prefs.skipRenderPromptAfterProcessing) {
            renderQuestion.disarm()
            svm.processAll()
        } else {
            preRenderFlow.open()
            _showPreRenderPrompt.value = true
        }
    }

    /** [settings]: how to render at the end of the run when [autoRender], as chosen in the options step; null renders from the config. */
    fun confirmStartProcessing(autoRender: Boolean, dontAskAgain: Boolean, settings: com.star.proto.VideoEncodeSettings? = null) {
        if (dontAskAgain) prefs.setSkipRenderPrompt(true)
        armRenderQuestion(render = autoRender, ask = !dontAskAgain, settings = settings)
        preRenderFlow.reset()
        _showPreRenderPrompt.value = false
        currentSequence?.processAll()
    }

    /** The prompt's Yes: the render options come next, and nothing starts yet. */
    fun chooseRenderOptions() { preRenderFlow.yes() }

    /** Cancel in the render options: back to the question, with nothing started. */
    fun cancelRenderOptions() { preRenderFlow.cancelOptions() }

    /** "Use These Settings": process, and render with [settings] when it is done. */
    fun confirmRenderOptions(settings: com.star.proto.VideoEncodeSettings) {
        val start = preRenderFlow.confirm(settings) ?: return
        confirmStartProcessing(start.autoRender, start.dontAskAgain, start.settings)
    }

    fun dismissPreRenderPrompt() { preRenderFlow.reset(); _showPreRenderPrompt.value = false }
    fun dismissPostRenderPrompt() { _showPostRenderPrompt.value = false }

    /** Post-prompt "Preview first": play the final frames from the start. */
    fun previewFinalFrames() {
        _showPostRenderPrompt.value = false
        currentSequence?.let {
            it.setViewMode(com.star.proto.FrameViewMode.VIEW_PROCESSED)
            it.goToFirst()
            it.startPlaybackForward() // from the start, forward, and not toggled off if it was already playing
        }
    }

    fun confirmRenderAfterProcessing() {
        _showPostRenderPrompt.value = false
        openRenderVideo(autoStart = true)
    }

    private fun handleProcessingDone() {
        val settings = renderQuestion.renderSettings   // done() drops them
        when (renderQuestion.done(currentSequence?.runsStarted ?: 0)) {
            RenderQuestion.Outcome.RENDER -> openRenderVideo(autoStart = true, settings = settings)
            RenderQuestion.Outcome.ASK -> _showPostRenderPrompt.value = true
            RenderQuestion.Outcome.NOTHING -> Unit
        }
    }

    private val _showOutlierWindow = MutableStateFlow(false)
    val showOutlierWindow: StateFlow<Boolean> = _showOutlierWindow.asStateFlow()
    fun toggleOutlierWindow() { _showOutlierWindow.value = !_showOutlierWindow.value }
    fun closeOutlierWindow() { _showOutlierWindow.value = false }

    private val _showAlignmentWindow = MutableStateFlow(false)
    val showAlignmentWindow: StateFlow<Boolean> = _showAlignmentWindow.asStateFlow()
    fun toggleAlignmentWindow() { _showAlignmentWindow.value = !_showAlignmentWindow.value }
    fun openAlignmentWindow() { _showAlignmentWindow.value = true }
    fun closeAlignmentWindow() { _showAlignmentWindow.value = false }

    /** Keeps the machine from sleeping while a sequence is open; a replacement can be given for a test. */
    internal var sleepInhibitor: com.star.desktop.util.SleepInhibitor = com.star.desktop.util.SleepInhibitor()

    private val _showBlobWindow = MutableStateFlow(false)
    val showBlobWindow: StateFlow<Boolean> = _showBlobWindow.asStateFlow()
    fun toggleBlobWindow() { _showBlobWindow.value = !_showBlobWindow.value }
    fun closeBlobWindow() { _showBlobWindow.value = false }

    /** The Blob Processing window's steps, from the engine. */
    val blobProcessing = com.star.desktop.ui.windows.BlobProcessingModel(scope, com.star.desktop.data.BlobRepository { engine.client })

    private val _showDebugWindow = MutableStateFlow(false)
    val showDebugWindow: StateFlow<Boolean> = _showDebugWindow.asStateFlow()
    fun toggleDebugWindow() { _showDebugWindow.value = !_showDebugWindow.value }
    fun closeDebugWindow() { _showDebugWindow.value = false }

    /** The Debug window's choices: the log's level, and the files it is written to. */
    val debugLog = DebugLogSettings(
        scope,
        tellEngine = { level, fileEnabled, fileLevel ->
            try {
                engine.client?.setLogLevel(level, fileEnabled, fileLevel)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                com.star.desktop.util.Log.w("App") { "could not tell the engine its log level: ${e.message}" }
                null
            }
        },
        logsDirectory = { java.io.File(engine.engineLogPath).parentFile },
    )

    /** Where the engine's log (everything it writes to stderr) is kept. */
    val engineLogPath: String get() = engine.engineLogPath

    private val _showInfoDialog = MutableStateFlow(false)
    val showInfoDialog: StateFlow<Boolean> = _showInfoDialog.asStateFlow()
    fun openInfoDialog() { _showInfoDialog.value = true }
    fun closeInfoDialog() { _showInfoDialog.value = false }

    // Which tab of the Info dialog was last open, kept for the app's life (macOS `ViewModel.currentInfoType`), not for each time it opens.
    private val _currentInfoType = MutableStateFlow(com.star.desktop.ui.dialogs.InfoType.ABOUT)
    val currentInfoType: StateFlow<com.star.desktop.ui.dialogs.InfoType> = _currentInfoType.asStateFlow()
    fun setInfoType(type: com.star.desktop.ui.dialogs.InfoType) { _currentInfoType.value = type }

    // §4.4: non-blocking warning when a resumed session's config.starVersion ≠ the running engine.
    private val _versionWarning = MutableStateFlow<String?>(null)
    val versionWarning: StateFlow<String?> = _versionWarning.asStateFlow()
    fun dismissVersionWarning() { _versionWarning.value = null }

    // ---- a new release (macOS NewReleaseSheetView) ----
    private val _newRelease = MutableStateFlow<com.star.desktop.util.GitHubRelease?>(null)

    /** A release newer than the one running, to tell the user about on the start screen; null when there is none or it was put off. */
    val newRelease: StateFlow<com.star.desktop.util.GitHubRelease?> = _newRelease.asStateFlow()

    /** The version of the engine, which is the version of Star running (they are one release). */
    val runningVersion: String? get() = (engine.status.value as? EngineStatus.Connected)?.daemonVersion

    /** "Upgrade Later". */
    fun dismissNewRelease() { _newRelease.value = null }

    // ---- engine warnings pushed by the daemon ----
    //
    // Memory pressure, output it could not write, a disk with no room. Before the daemon could
    // push these they went only to its stderr, which this client drains into a sink that in a
    // packaged app goes nowhere a user can read — so a run walking into an out-of-memory kill
    // looked completely normal right up until the engine died.
    //
    // Routed as the Mac app does (see WarningRouting): a critical one interrupts once per kind; everything else is a banner, which comes down by
    // itself after a minute when it is about a state that passes and stays until dismissed otherwise.
    private val _warningState = MutableStateFlow(WarningState())
    val warningState: StateFlow<WarningState> = _warningState.asStateFlow()
    private var bannerExpiry: Job? = null

    /** A warning from the engine. */
    fun report(warning: com.star.proto.Warning) {
        _warningState.update { WarningRouting.report(it, warning, System.currentTimeMillis()) }
        val banner = _warningState.value.banner
        // The newest report wins, so whatever timer was running was for one that is gone.
        bannerExpiry?.cancel()
        bannerExpiry = null
        if (banner != null && banner.warning === warning) {
            WarningRouting.lifetimeMs(warning)?.let { lifetime ->
                bannerExpiry = scope.launch {
                    delay(lifetime)
                    _warningState.update { WarningRouting.expire(it, banner) }
                }
            }
        }
    }

    fun dismissBanner() {
        bannerExpiry?.cancel()
        bannerExpiry = null
        _warningState.update { WarningRouting.dismissBanner(it) }
    }

    /** The critical warning's OK. */
    fun acknowledgeWarning() { _warningState.update { WarningRouting.acknowledge(it) } }

    // ---- new-source startup prompts (macOS StartupView) ----
    private val _startupStep = MutableStateFlow<StartupStep?>(null) // null = not showing
    val startupStep: StateFlow<StartupStep?> = _startupStep.asStateFlow()
    // The answers are not kept here: each is written into the session config as it is given (macOS does the
    // same through the view model's didSet), so the config is the one record of them, a resumed session has
    // them from the start, and closing the prompts or opening Advanced cannot lose or overwrite them.
    private val startupHasHorizon: Boolean get() = sessions.session.value?.config?.horizonDetectionEnabled ?: false
    private val startupCameraMoving: Boolean get() = sessions.session.value?.config?.tripodHeadWasMoving ?: false

    /** The latest startup answer being written, so the next one is written after it. */
    private var startupWrite: Job? = null

    /** Write one startup answer into the session config, after any still being written. */
    private fun writeStartupAnswer(change: (Config.Builder) -> Unit): Job {
        val previous = startupWrite
        val job = scope.launch {
            previous?.join()
            val current = runCatching { sessions.getConfig() }.getOrNull() ?: return@launch
            runCatching { sessions.updateConfig(current.toBuilder().also(change).build()) }
        }
        startupWrite = job
        return job
    }

    /**
     * Whether this machine can detect on the open sequence at full resolution (the "Speed vs. Sharpness" advice on the removal prompt), or
     * null when the daemon could not say. Asked fresh each time: it depends on settings that move it, such as use of this Mac.
     */
    suspend fun keypointAdvice(): com.star.proto.KeypointDivisorAdvice? =
        runCatching { sessions.getKeypointAdvice() }
            .onFailure { Log.w("App") { "could not get the keypoint divisor advice: ${it.message}" } }
            .getOrNull()

    /**
     * The "Speed vs. Sharpness" value, written into the session config as it is typed or picked (macOS does the same through the view
     * model's didSet): Start Processing is right beside the field, and a value held back until "commit" would be lost to the click on it.
     * Sending it is also what marks it chosen, so the daemon's automatic default does not pick another over it.
     */
    fun setKeypointDivisor(divisor: Double) {
        writeStartupAnswer { it.setAlignmentKeypointDetectionDivisor(divisor) }
    }

    /** Prompt 1 answer: does the sequence include a horizon? */
    fun startupAnswerHorizon(hasHorizon: Boolean) {
        writeStartupAnswer { it.setHorizonDetectionEnabled(hasHorizon) }
        _startupStep.value = StartupStep.MOVING
    }

    /** Prompt 2 answer: was the camera moving (false = static on a tripod)? */
    fun startupAnswerMoving(moving: Boolean) {
        val written = writeStartupAnswer { it.setTripodHeadWasMoving(moving) }
        scope.launch {
            written.join()
            _startupStep.value = stepAfterCameraMotion(startupHasHorizon, moving)
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
            startupWrite?.join() // the answers that led here are in the config before references are saved against it
            val indices = evenlySpacedFrameIndices(count, svm.frameCount)
            svm.beginStartupHorizon(indices)
            recordStartupHorizonProgress(indices, 0)
            _startupStep.value = null
        }
    }

    /** Static SelectHorizon "Yes": paint the single current frame in startup mode. */
    private fun startStaticHorizonStartupFlow() {
        val svm = currentSequence ?: return
        scope.launch {
            startupWrite?.join()
            // A one-frame list rather than the empty one this used to pass, so an interrupted
            // static selection resumes by the same route as a moving one. See
            // SequenceViewModel.beginStartupHorizon for why nothing downstream notices.
            val indices = listOf(svm.currentIndex.value)
            svm.beginStartupHorizon(indices)
            recordStartupHorizonProgress(indices, 0)
            _startupStep.value = null
        }
    }

    /** Painter "Next"/"Continue" in startup mode: advance to the next frame, or finish → removal. */
    fun startupHorizonAdvanceOrContinue() {
        val svm = currentSequence ?: return
        if (svm.startupHorizonHasMore()) {
            svm.advanceStartupHorizon()
            scope.launch {
                recordStartupHorizonProgress(svm.startupHorizonIndices.value,
                                             svm.startupHorizonPosition.value)
            }
        } else {
            continueToRemovalFromHorizonPainter()
        }
    }

    /** Finish startup horizon painting → show the removal prompt (macOS `continueToRemovalFromHorizonPainter`). */
    fun continueToRemovalFromHorizonPainter() {
        currentSequence?.endStartupHorizon()
        scope.launch { recordStartupHorizonProgress(emptyList(), 0) } // finished: nothing to resume
        _startupStep.value = StartupStep.REMOVAL
    }

    /** Painter "Cancel" in startup mode → back to the moving/stationary question (macOS `returnToMovingViewFromHorizonPainter`). */
    fun cancelStartupHorizon() {
        currentSequence?.endStartupHorizon()
        scope.launch { recordStartupHorizonProgress(emptyList(), 0) } // backed out: nothing to resume
        _startupStep.value = StartupStep.MOVING
    }

    /**
     * Mirror the painter's position in the startup horizon flow into the session config, so a
     * selection the user is part way through survives the session.
     *
     * Written on every step, not once at the end: the session this protects against is the one
     * that was killed or quit mid-paint, which gets no chance to clean up. Losing it means
     * re-opening straight into processing, with the frames the user never reached falling back
     * to the automatic horizon detection they had just declined.
     */
    private suspend fun recordStartupHorizonProgress(indices: List<Int>, position: Int) {
        val current = runCatching { sessions.getConfig() }.getOrNull() ?: return
        val b = current.toBuilder()
            .clearStartupHorizonFrameIndices()
            .addAllStartupHorizonFrameIndices(indices)
            // Set even when clearing: the daemon gates the pair on the position being
            // *present*, since a repeated field cannot be optional and an empty list would
            // otherwise be indistinguishable from a client that knows nothing about these.
            .setStartupHorizonFramePosition(position)
        runCatching { sessions.updateConfig(b.build()) }
    }

    /**
     * Put the painter back on a hand-painted horizon selection the last session did not finish.
     *
     * The horizons already painted are on disk, so only the frames from the recorded position
     * on are left to do. Finishing them lands on the removal prompt, which starts the run the
     * ordinary way — which is the point: processing before the selection is done runs the
     * frames the user never reached with the automatic detection they had just declined.
     */
    private fun resumeStartupHorizonIfUnfinished(svm: SequenceViewModel, config: Config): Boolean {
        val indices = config.startupHorizonFrameIndicesList
        val position = config.startupHorizonFramePosition
        if (startupHorizonResumeFrame(indices, position, svm.frameCount) == null) {
            if (indices.isNotEmpty()) {
                Log.w("App") { "startup horizon selection at $position of $indices does not fit ${svm.frameCount} frames; not resuming" }
            }
            return false
        }
        Log.i("App") { "resuming hand painted horizon selection at ${position + 1} of ${indices.size}" }
        svm.beginStartupHorizon(indices, position)
        return true
    }

    // ---- "where this sequence left off" (macOS SequenceProgressModalView) ----
    private val _sequenceProgress = MutableStateFlow<SequenceProgress?>(null)

    /** How far the last run got, while the panel that says so is up; null otherwise. */
    val sequenceProgress: StateFlow<SequenceProgress?> = _sequenceProgress.asStateFlow()

    /**
     * Survey what the last run left on disk and put the panel up. Asked once, as the sequence is reopened, so the numbers are what that
     * run left and not a running count (a run started from the panel reports itself through the processing screen). A survey that fails
     * is not worth failing the open over: the user simply goes on to the frames.
     */
    private fun showSequenceProgress(svm: SequenceViewModel) {
        scope.launch {
            runCatching { sessions.getProgressSurvey() }
                .onSuccess { if (currentSequence === svm) _sequenceProgress.value = it }
                .onFailure { Log.w("App") { "could not survey the sequence's progress: ${it.message}" } }
        }
    }

    fun closeSequenceProgress() { _sequenceProgress.value = null }

    /**
     * The panel's Start/Finish Processing: the whole sequence rather than a range from the first unwritten frame, since the frames that
     * are not finished are not necessarily a contiguous tail (any frame can be reprocessed, and a stopped run leaves holes wherever its
     * workers happened to be) and a frame whose output is written is skipped anyway. Edit mode, where the frames and the progress are.
     */
    fun finishProcessingOpenedSequence() {
        closeSequenceProgress()
        currentSequence?.setMode(com.star.desktop.domain.InteractionMode.EDIT)
        requestProcessAll()
    }

    /** The panel's Render Video. */
    fun renderVideoForOpenedSequence() {
        closeSequenceProgress()
        currentSequence?.setMode(com.star.desktop.domain.InteractionMode.EDIT)
        openRenderVideo()
    }

    /** The panel's Settings: the Processing Settings, in edit mode like the panel's other actions. */
    fun openSettingsForOpenedSequence() {
        closeSequenceProgress()
        currentSequence?.setMode(com.star.desktop.domain.InteractionMode.EDIT)
        openSettings()
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

    /** "Back" on a startup prompt: return to the previous question without discarding later answers. */
    fun startupGoBack(step: StartupStep) {
        _startupStep.value = previousStartupStep(step, startupHasHorizon, startupCameraMoving)
    }

    /** "Advanced" gear on a prompt: open the settings. The answers so far are already in the config the dialog shows. */
    fun startupOpenAdvanced() {
        scope.launch {
            startupWrite?.join()
            _startupStep.value = null
            openSettings()
        }
    }

    /** Removal prompt "Start Processing": apply the chosen clean method + answers, then process. */
    fun startupStartProcessing(cleanMethod: CleanMethod, allowEarthAlignment: Boolean) {
        scope.launch {
            startupWrite?.join()
            applyRemovalChoices(cleanMethod, allowEarthAlignment)
            _startupStep.value = null
            requestProcessAll()
        }
    }

    /** Removal prompt "Close": dismiss the prompts without processing. The answers given stay in the config. */
    fun dismissStartup() { _startupStep.value = null }

    /**
     * Put the removal prompt's choices (a clean method, and the "Cars" toggle's earth alignment) into the live
     * session config. [allowEarthAlignment] defaults to true, matching the macOS behavior of earth alignment being
     * on by default.
     */
    private suspend fun applyRemovalChoices(cleanMethod: CleanMethod? = null, allowEarthAlignment: Boolean = true) {
        val current = runCatching { sessions.getConfig() }.getOrNull() ?: return
        runCatching { updateSessionConfig(withRemovalChoices(current, cleanMethod, allowEarthAlignment)) }
    }

    init {
        scope.launch { engine.start() }
        // Once, when the engine has said what version this is.
        scope.launch {
            val connected = engine.status.first { it is EngineStatus.Connected } as EngineStatus.Connected
            _newRelease.value = releaseCheck(connected.daemonVersion)
        }
        // A fresh engine starts at its own log level: the one chosen in the Debug window is said to it again.
        scope.launch { engine.status.collect { if (it is EngineStatus.Connected) debugLog.reapplyToEngine() } }
        scope.launch {
            // Latest wins: these describe the machine's current state, so an older one being
            // replaced by a newer is right. The user can dismiss, and the next one re-raises.
            engine.warnings.collect { report(it) }
        }
        scope.launch {
            engine.status.collect { st ->
                // Engine died: say why and offer Restart. With a session open, don't tear it down yet —
                // restart re-opens it via OpenConfig. On the start screen this is the only place the
                // reason appears at all: an engine that failed to come up used to show just a red
                // "engine stopped" badge, and the user found out only by trying to open something and
                // getting "RPC error -1: engine not connected". A deliberate restart() sets
                // `restarting` to suppress this.
                if (st is EngineStatus.Failed && _screen.value !is AppScreen.Loading && _screen.value !is AppScreen.Opening && !restarting) {
                    _engineDown.value = st.message
                }
            }
        }
        if (autoOpenPath != null) {
            when (com.star.desktop.ui.initial.inferOpenKind(autoOpenPath)) {
                com.star.desktop.ui.initial.OpenKind.SEQUENCE -> openSequence(autoOpenPath)
                com.star.desktop.ui.initial.OpenKind.VIDEO -> openVideo(autoOpenPath, com.star.desktop.domain.VideoImportOptions())
                com.star.desktop.ui.initial.OpenKind.CONFIG -> openConfig(autoOpenPath)
            }
        }
    }

    fun openSequence(dir: String, outputDir: String? = null) =
        launchOpen(dir, video = false, promptStartup = true) { sessions.openSequenceStream(dir, initialConfigBeside(dir, savedDetectionType(), outputDir)) }

    /** A sequence the user chose, waiting on the dialog that asks where its output and working files go and says what room they need. */
    private val _pendingSequence = MutableStateFlow<String?>(null)
    val pendingSequence: StateFlow<String?> = _pendingSequence.asStateFlow()

    /** What the menu and the start screen call: asks about the location first; [openSequence] is the open itself. */
    fun requestSequence(dir: String) { _pendingSequence.value = dir }
    fun cancelSequenceLocation() { _pendingSequence.value = null }
    fun confirmSequenceLocation(outputDir: String?) {
        val dir = _pendingSequence.value ?: return
        _pendingSequence.value = null
        openSequence(dir, outputDir)
    }

    fun openConfig(path: String, thenProcess: Boolean = false) =
        launchOpen(path, video = false, afterOpen = if (thenProcess) ::resumeProcessing else null) { sessions.openConfigStream(path) }

    /**
     * The critical warning's "Restart Now" (macOS `restartAbandonedRun`): open again the sequence a run that was killed was working on, and carry
     * on processing it. Everything a resume needs is in the config that run wrote (which frames are finished is read off the disk), so this is the
     * ordinary re-open with the press of the button that follows it made for the user. Acknowledges first: the user has acted on the report, and
     * leaving the kind unacknowledged would let a second report put the same dialog back over the sequence that is loading.
     */
    fun restartAbandonedRun(configPath: String) {
        acknowledgeWarning()
        Log.i("App") { "restarting the run that stopped, from $configPath" }
        openConfig(configPath, thenProcess = true)
    }

    /**
     * Start processing the sequence that has just been opened again, with no question about rendering (it is a run being picked back up, and
     * "render a video afterwards?" is not what its button promised). Not over a hand-painted horizon selection the last session never finished: the
     * open has already put the painter back up, and processing now would run without the horizons the user asked to define.
     */
    private fun resumeProcessing() {
        val svm = currentSequence ?: return
        if (svm.horizonPaintMode.value) return
        svm.setMode(com.star.desktop.domain.InteractionMode.EDIT)
        armRenderQuestion(render = false, ask = com.star.desktop.domain.ResumedRun.asksAboutRenderingAtTheEnd(prefs.skipRenderPromptAfterProcessing))
        svm.processAll()
    }

    /** Output goes beside the video, as macOS puts it (the parent of the extracted frames' folder is the video's own folder), not in the daemon's hidden per-session scratch fallback. */
    fun openVideo(path: String) { _pendingVideo.value = path }

    /** A video the user chose, waiting on the import dialog that asks how its frames are written. */
    private val _pendingVideo = MutableStateFlow<String?>(null)
    val pendingVideo: StateFlow<String?> = _pendingVideo.asStateFlow()
    fun cancelVideoImport() { _pendingVideo.value = null }

    /**
     * The import dialog's answer: extract the pending video to frames as [options] say (in the format and compression chosen, and in the
     * background or not) and open it.
     */
    fun confirmVideoImport(options: com.star.desktop.domain.VideoImportOptions) {
        val path = _pendingVideo.value ?: return
        _pendingVideo.value = null
        openVideo(path, options)
    }

    /**
     * Open a video. With [com.star.desktop.domain.VideoImportOptions.extractInBackground] the engine answers once the first frame is out, so the
     * sequence screen comes up while the rest are still being extracted (it marks the frames that are not there yet).
     */
    fun openVideo(
        path: String,
        options: com.star.desktop.domain.VideoImportOptions = com.star.desktop.domain.VideoImportOptions(),
    ) = launchOpen(path, video = true, promptStartup = true) {
        sessions.openVideo(path, initialConfigBeside(path, savedDetectionType(), options.outputDir), options)
    }

    private var openJob: Job? = null

    /**
     * The loading screen's Cancel: give up on the source being opened and go back to the start screen. Cancelling the job is what stops the
     * daemon (it is told, stops ffmpeg if it was decoding, and leaves no session behind). Does nothing once the open has finished, so a click
     * that races the last frame cannot leave a session open behind the start screen.
     */
    fun cancelOpen() {
        var wasOpening = false
        _screen.update { wasOpening = it is AppScreen.Opening; if (wasOpening) AppScreen.Initial else it }
        if (wasOpening) openJob?.cancel()
    }

    /**
     * [opened], the session just opened, with its GPU toggles as the user last set them on this machine, which win over whatever a re-opened
     * sequence's `config.json` was saved with (a new one starts from the daemon's defaults, on wherever a GPU is available). A toggle never chosen
     * is left as it is. Applied straight to the session, not through [updateSessionConfig], so it is not remembered again as if the user had just
     * changed it. A daemon that refuses it leaves the session as it opened.
     */
    private suspend fun withGpuPreferences(opened: SessionInfo): SessionInfo {
        val changes = GpuToggle.changesToMatch(prefs::gpu, opened.config) ?: return opened
        return try {
            sessions.updateConfig(changes)
            sessions.session.value ?: opened
        } catch (e: CancellationException) {
            throw e
        } catch (e: Throwable) {
            Log.w("App") { "could not apply the saved GPU settings: ${e.message}" }
            opened
        }
    }

    /** Open a source from [source], which streams how it is going and ends with the session: shows that on the loading screen, then the sequence. */
    private fun launchOpen(path: String, video: Boolean, promptStartup: Boolean = false, afterOpen: (() -> Unit)? = null, source: () -> Flow<OpenProgress>) {
        openJob = scope.launch {
            ensureConnected()
            if (engine.client == null) {
                // Opening would only fail with "RPC error -1: engine not connected" — what the Windows
                // user kept getting. Show why the engine isn't there, with Restart, instead.
                showEngineDown()
                return@launch
            }
            var progress = com.star.desktop.domain.LoadingProgress.starting(java.io.File(path).name, video)
            _screen.value = AppScreen.Opening(progress)
            try {
                closeOpenSession() // opening over an open session: cancel it, close it, then open
                var info: SessionInfo? = null
                source().collect { event ->
                    if (event.kindCase == OpenProgress.KindCase.DONE) {
                        info = event.done
                    } else {
                        progress = progress.after(event)
                        // Only while the loading screen is still up: a Cancel has already put the start screen back.
                        _screen.update { if (it is AppScreen.Opening) AppScreen.Opening(progress) else it }
                    }
                }
                val opened = info ?: run { fail(localized(if (video) "ui.video_import_produced_no_session" else "ui.opening_produced_no_session")); return@launch }
                if (_screen.value !is AppScreen.Opening) {
                    // Cancelled just as it finished: the daemon has a session nobody here will use.
                    withContext(NonCancellable) { runCatching { engine.client?.closeSession(opened.sessionId) } }
                    return@launch
                }
                sessions.applySessionInfo(opened)
                onOpened(path, withGpuPreferences(opened), promptStartup = promptStartup, showProgress = com.star.desktop.domain.ResumedRun.showsProgressPanel(resuming = afterOpen != null))
                afterOpen?.invoke()
            } catch (e: CancellationException) {
                throw e
            } catch (e: Throwable) {
                fail(e.message ?: localized(if (video) "ui.failed_to_import_video" else "ui.failed_to_open"))
            }
        }
    }

    // ---- closing and quitting with work going (macOS `hasPendingWork`, AppDelegate, File ▸ Close) ----

    private val _closeConfirmation = MutableStateFlow<CloseConfirmation?>(null)

    /** The question up over the window before something that would interrupt work; null when none is. */
    val closeConfirmation: StateFlow<CloseConfirmation?> = _closeConfirmation.asStateFlow()

    /** What leaving would interrupt: a run, frames rendered again, a video encoded, edits not yet saved. */
    fun pendingWork(): PendingWork {
        val svm = currentSequence ?: return PendingWork.NONE
        return PendingWork(
            processing = svm.isProcessing.value, renderingFrames = svm.rendering.value, renderingVideo = isRendering, savingFrames = svm.pendingSaves.value,
        )
    }

    /** What happens once the app is done, set by whoever owns the window (it exits the application). */
    var onQuit: () -> Unit = {}

    /** What the main window's close button does on this system ([MainWindowClose]); settable for a test. */
    var mainWindowClose: com.star.desktop.domain.MainWindowClose = com.star.desktop.domain.MainWindowClose.current

    private val _mainWindowVisible = MutableStateFlow(true)

    /** Whether the main window is showing; false after it was closed where the app keeps running, until it is raised again. */
    val mainWindowVisible: StateFlow<Boolean> = _mainWindowVisible.asStateFlow()

    /**
     * The main window's close button. Where the app stays running (macOS, as the gui does) this unloads the sequence, after asking if that would
     * interrupt anything ("Close Anyway"), and hides the window; elsewhere it is a quit.
     */
    fun requestCloseWindow() {
        if (mainWindowClose == com.star.desktop.domain.MainWindowClose.QUIT) { requestQuit(); return }
        val work = pendingWork()
        if (work.isPending) _closeConfirmation.value = CloseConfirmation(CloseAction.CLOSE_WINDOW, work.description()) else closeWindowNow()
    }

    /** The app was raised (the Dock icon, Cmd-Tab) with its window gone: a fresh window, on the start screen, as the gui's reopens. */
    fun reopenMainWindow() { _mainWindowVisible.value = true }

    private fun closeWindowNow() {
        scope.launch {
            unloadSession()
            _mainWindowVisible.value = false
        }
    }

    /** Cmd-Q (and Quit in the app menu): quit, after asking if that would interrupt anything. */
    fun requestQuit() {
        val work = pendingWork()
        if (work.isPending) _closeConfirmation.value = CloseConfirmation(CloseAction.QUIT, work.description()) else quitNow()
    }

    /** File ▸ Close: close the sequence, after asking if that would interrupt anything. */
    fun requestCloseSession() {
        if (currentSequence == null) return
        val work = pendingWork()
        if (work.isPending) _closeConfirmation.value = CloseConfirmation(CloseAction.CLOSE_SESSION, work.description()) else closeSession()
    }

    /** What File ▸ Open… was going to do, held while the question about the work it would interrupt is up. */
    private var pendingOpen: (() -> Unit)? = null

    /**
     * File ▸ Open Image Sequence…, Open Video…, Resume…: run [open], which asks the user what to open, once it is clear that nothing is
     * going to be interrupted, or the user has said it may be. Opening closes the sequence that is open, so it is held to the same question
     * as File ▸ Close (it used to close the session, run and all, without asking). Asked before the chooser, not after it, so no one picks
     * a file to be told it cannot be opened.
     */
    fun requestOpen(open: () -> Unit) {
        val work = pendingWork()
        if (!work.isPending) {
            open()
            return
        }
        pendingOpen = open
        _closeConfirmation.value = CloseConfirmation(CloseAction.OPEN, work.description())
    }

    /** The question's yes: do what was asked, interrupting what is going. */
    fun confirmClose() {
        val asked = _closeConfirmation.value ?: return
        _closeConfirmation.value = null
        val open = pendingOpen
        pendingOpen = null
        when (asked.action) {
            CloseAction.QUIT -> quitNow()
            CloseAction.CLOSE_SESSION -> closeSession()
            CloseAction.CLOSE_WINDOW -> closeWindowNow()
            CloseAction.OPEN -> open?.invoke()
        }
    }

    /** The question's no: nothing is interrupted, and what was asked for is dropped with it. */
    fun cancelClose() {
        _closeConfirmation.value = null
        pendingOpen = null
    }

    /**
     * Quit: ask the engine to shut down first, so it writes out what is pending and clears its run marker. Killing it instead leaves the marker,
     * and the next launch reports a crash that did not happen (Windows has no gentler way to stop a process than the one the JVM's exit hook
     * uses). Waits a few seconds at most, and goes on without it if the engine does not answer.
     */
    private fun quitNow() {
        sleepInhibitor.release()
        scope.launch {
            withTimeoutOrNull(QUIT_WAIT_MS) { runCatching { shutdown() } }
            onQuit()
        }
    }

    fun closeSession() {
        scope.launch { unloadSession() }
    }

    private suspend fun unloadSession() {
        closeOpenSession()
        lastResumePath = null // nothing is open, so a crash from here on has nothing to resume
        _screen.value = AppScreen.Initial
    }

    /**
     * End the open session completely: the UI side, then `Session.Close` on the daemon, which stops
     * its run and waits for it, writes out what is pending, and ends its streams. Opening a new
     * source goes through here first, so the old session is closed rather than just forgotten.
     */
    private suspend fun closeOpenSession() {
        teardownSequence()
        runCatching { sessions.close() }
    }

    /**
     * The UI side of closing a session: stop its view model, cancel every coroutine started for it,
     * and reset the app-level state that only made sense for it (render prompts, open dialogs, the
     * startup answers, the version warning) so the next session starts clean.
     */
    private fun teardownSequence() {
        sleepInhibitor.release()
        currentSequence?.close()
        currentSequence = null
        sessionScope?.cancel()
        sessionScope = null

        preRenderFlow.reset()
        _showPreRenderPrompt.value = false
        _showPostRenderPrompt.value = false
        renderQuestion.disarm()
        // A condition acknowledged about the sequence just closed is not acknowledged about the next, and a banner about it is not still up.
        bannerExpiry?.cancel()
        bannerExpiry = null
        _warningState.update { WarningRouting.reset(it) }
        _showSettings.value = false
        _showCustomLimits.value = false
        _sequenceProgress.value = null
        renderJob?.cancel()
        _renderState.value = RenderState.Choosing
        _showRenderVideo.value = false
        _renderVideoAutoStart.value = false
        pendingRenderSettings = null
        _showOutlierWindow.value = false
        _showAlignmentWindow.value = false
        _showInfoDialog.value = false
        _startupStep.value = null
        _versionWarning.value = null
    }

    fun dismissError() { _error.value = null }

    /** Restart a crashed engine and re-open the last session from its config.json (§2.1 crash recovery). */
    fun restartEngine() {
        val resume = lastResumePath
        // A run that was going when the engine died is taken up again once the session is back: the user restarted the engine to carry on, and a
        // sequence reopened idle, with the run's progress still on the disk, would look as if the restart had lost it.
        val wasProcessing = currentSequence?.isProcessing?.value == true
        scope.launch {
            restarting = true
            _engineDown.value = null
            _screen.value = AppScreen.Loading("ui.restarting_engine", null, null)
            val ok = engine.restart()
            restarting = false
            if (!ok) {
                _screen.value = AppScreen.Initial
                showEngineDown()
                return@launch
            }
            if (resume != null && java.io.File(resume).exists()) {
                _screen.value = AppScreen.Loading("ui.resuming_session", resume, null)
                try {
                    onOpened(resume, sessions.openConfig(resume), addToRecent = false, showProgress = com.star.desktop.domain.ResumedRun.showsProgressPanel(resuming = wasProcessing))
                    if (wasProcessing) resumeProcessing()
                } catch (e: Throwable) {
                    fail(e.message ?: localized("ui.failed_to_resume_the_session_after_the_restart"))
                }
            } else {
                _screen.value = AppScreen.Initial
            }
        }
    }

    /** Raise the engine-down overlay with whatever the engine said about its death. */
    private fun showEngineDown() {
        _engineDown.value = (engine.status.value as? EngineStatus.Failed)?.message ?: localized("ui.engine_stopped")
    }

    /** Give up on a crashed engine: close the dead session and return to the start screen. */
    fun dismissEngineDown() {
        _engineDown.value = null
        teardownSequence()
        lastResumePath = null
        runCatching { sessions.clearLocal() }
        _screen.value = AppScreen.Initial
    }

    fun removeRecent(path: String) {
        prefs.removeRecentFile(path)
        _recentFiles.value = prefs.recentFiles
    }

    suspend fun shutdown() = engine.shutdown()

    private fun onOpened(path: String, info: SessionInfo, addToRecent: Boolean = true, promptStartup: Boolean = false, showProgress: Boolean = true) {
        // Normally the open has already closed what was open; this is for the restart-after-crash route,
        // where the old session died with the engine. Before anything below sets state for the new one.
        teardownSequence()
        // The session's on-disk config.json — the resume path for crash recovery (cross-client
        // resume). Reported by the daemon rather than built from the scratch dir: a session
        // opened from a config keeps writing to the caller's own file, which is somewhere
        // else entirely, so the constructed path named a file nothing ever wrote and
        // restartEngine() gave up on a session that was perfectly resumable.
        val configPath = info.configJsonPath.ifEmpty { "${info.scratchSessionDir}/config.json" }
        lastResumePath = configPath
        if (addToRecent) {
            // The config, whatever was opened: that is what the macOS app records, and what either client
            // opens a recent entry as, resuming the session rather than starting a fresh one (with its
            // startup questions, and a video decoded again) from the folder or video it came from.
            prefs.addRecentFile(configPath)
            _recentFiles.value = prefs.recentFiles
        }
        _engineDown.value = null
        // Warn if the session was last written by a different engine version (req #4).
        val engineVer = (engine.status.value as? EngineStatus.Connected)?.daemonVersion
        _versionWarning.value = com.star.desktop.util.versionMismatchWarning(info.config.starVersion, engineVer)
        val sessionScope = CoroutineScope(scope.coroutineContext + SupervisorJob(scope.coroutineContext[Job]))
        this.sessionScope = sessionScope
        val proc = ProcessingRepository(sessionScope) { engine.client }
        // Fire the post-processing render prompt when a prompted process-all run reaches "done"; a
        // run the user stopped must not leave it armed for whichever run reaches "done" next.
        sessionScope.launch {
            proc.sequenceState.collect {
                when (it) {
                    "done" -> handleProcessingDone()
                    // A stopped or failed run is not one to offer a render for.
                    "cancelled", "error" -> renderQuestion.disarm()
                }
            }
        }
        sessionScope.launch { proc.errors.collect(::report) }
        val svm = SequenceViewModel(sessionScope, info, frameRepo, proc, outlierRepo, imageCache, export, horizonRepo, onError = ::report, prefs = prefs,
            alignmentSource = { alignmentRepo.sequence(info.sessionId, includeHomography = false, includePreviews = false) })
        // A source opened for the first time starts in edit mode (macOS); one resumed from its config in scrub mode, where it was left.
        svm.setMode(com.star.desktop.domain.InteractionMode.onOpening(freshSource = promptStartup))
        when (autoMode) {
            "edit" -> svm.setMode(com.star.desktop.domain.InteractionMode.EDIT)
            "grid" -> svm.setMode(com.star.desktop.domain.InteractionMode.GRID)
            "align" -> toggleAlignmentWindow()
            "horizon" -> { svm.setMode(com.star.desktop.domain.InteractionMode.EDIT); svm.toggleHorizonPaint() }
            "info" -> openInfoDialog()                  // dev hook: screenshot the Info dialog
            "prerender" -> { preRenderFlow.open(); _showPreRenderPrompt.value = true }   // dev hook: screenshot the pre-render prompt
            "postrender" -> _showPostRenderPrompt.value = true // dev hook: screenshot the post-render prompt
            "multiselect" -> svm.openMultiSelect(SequenceViewModel.RectSelection(100f, 100f, 400f, 400f)) // dev hook
            "settings" -> openSettings() // dev hook: screenshot the Processing Settings dialog
            "startup" -> _startupStep.value = StartupStep.HORIZON // dev hook: startup prompts
            "removal" -> _startupStep.value = StartupStep.REMOVAL // dev hook: the last startup prompt
            "progress" -> showSequenceProgress(svm) // dev hook: screenshot the reopened-sequence panel
            else -> Unit
        }
        autoFrame?.let { svm.setCurrentIndex(it) }
        svm.openOutlierWindow = { _showOutlierWindow.value = true }
        currentSequence = svm
        _screen.value = AppScreen.Sequence(svm)
        // The machine is not to fall asleep under a long run for as long as a sequence is open (macOS does the same).
        sleepInhibitor.acquire()
        // Fresh source → walk the startup prompts (skipped for config resume + dev auto-open hooks).
        if (promptStartup && autoMode == null) {
            _startupStep.value = StartupStep.HORIZON
        } else if (autoMode == null) {
            // A config resume. Normally there is nothing to prompt for — the config already
            // carries the answers. The exception is a hand-painted horizon selection the last
            // session never finished, which has to come before processing rather than after.
            // The panel waits for that: a run started now would fall back to the automatic horizon detection they had declined.
            val painting = resumeStartupHorizonIfUnfinished(svm, info.config)
            if (!painting && showProgress) showSequenceProgress(svm)
        }
    }

    /** Show an error over whatever screen is up (macOS `report(error:)`); unlike [fail], leaves the screen alone. */
    fun report(message: String) {
        Log.w("App") { message }
        _error.value = message
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
