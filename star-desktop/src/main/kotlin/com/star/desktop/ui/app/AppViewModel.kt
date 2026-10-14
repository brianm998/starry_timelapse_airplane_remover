package com.star.desktop.ui.app

import com.star.desktop.data.FrameRepository
import com.star.desktop.data.ImageCache
import com.star.desktop.data.LocalPreferences
import com.star.desktop.i18n.Strings
import com.star.desktop.i18n.localized
import com.star.desktop.data.OutlierRepository
import com.star.desktop.data.ProcessingRepository
import com.star.desktop.data.SessionRepository
import com.star.desktop.domain.InteractionMode
import com.star.desktop.engine.EngineState
import com.star.desktop.engine.EngineStatus
import com.star.desktop.ui.sequence.SequenceViewModel
import com.star.desktop.util.Log
import com.star.proto.CleanMethod
import com.star.proto.Config
import com.star.proto.OpenProgress
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
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** What the root window is showing. */
sealed interface AppScreen {
    data object Initial : AppScreen
    data class Loading(val title: String, val detail: String?, val fraction: Float?) : AppScreen

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
 * The initial config for opening [source] (an image sequence's folder or a video file): selective cleaning,
 * previews on, and output written into the folder that holds the source, never left to the daemon's
 * per-session scratch fallback (a fresh hidden temp dir on every open). Config's `basename` already embeds
 * the sequence's own dirname, so this can't collide with a sibling sequence, and opening the same source
 * again resolves to the same output location, which is what lets `FrameAirplaneRemover.init`'s
 * `outputFileExistsOnDisk()` check find a previous run's output and report finished frames as complete
 * instead of unprocessed (macOS `inputImageSequencePath`).
 */
internal fun initialConfigBeside(source: String): Config =
    SessionRepository.defaultInitialConfig().toBuilder()
        .setOutputPath(java.io.File(source).parent ?: source)
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
        val before = sessions.session.value?.config?.cleanMethod
        val updated = sessions.updateConfig(config)
        if (before != null && updated.cleanMethod != before) currentSequence?.cleanMethodChanged(updated.cleanMethod)
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
            prefs.setString("processingType", type.name.removePrefix("DETECTION_").lowercase())
        }
    }

    /**
     * "Use of this Mac" (macOS ResourceProfileView): how much of the machine a run may take, `full`, `balanced`, `light` or `custom`. Applied to
     * the session at once, which reaches a run in progress (the daemon moves its limits then and there).
     */
    fun setResourceProfile(profile: String) {
        scope.launch {
            val current = runCatching { sessions.getConfig() }.getOrNull() ?: return@launch
            if (current.hasResourceProfile() && current.resourceProfile == profile) return@launch
            runCatching { updateSessionConfig(current.toBuilder().setResourceProfile(profile).build()) }.onFailure { report(it.message ?: it.toString()) }
        }
    }

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

    /** The render the prompt asked for has started: the dialog must not start another when something it watches changes. */
    fun consumeRenderVideoAutoStart() { _renderVideoAutoStart.value = false }

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
            it.startPlaybackForward() // from the start, forward, and not toggled off if it was already playing
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
        scope.launch {
            // Latest wins: these describe the machine's current state, so an older one being
            // replaced by a newer is right. The user can dismiss, and the next one re-raises.
            engine.warnings.collect { _engineWarning.value = it }
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
                com.star.desktop.ui.initial.OpenKind.VIDEO -> openVideo(autoOpenPath)
                com.star.desktop.ui.initial.OpenKind.CONFIG -> openConfig(autoOpenPath)
            }
        }
    }

    fun openSequence(dir: String) = launchOpen(dir, video = false, promptStartup = true) { sessions.openSequenceStream(dir, initialConfigBeside(dir)) }

    fun openConfig(path: String) = launchOpen(path, video = false) { sessions.openConfigStream(path) }

    /** Output goes beside the video, as macOS puts it (the parent of the extracted frames' folder is the video's own folder), not in the daemon's hidden per-session scratch fallback. */
    fun openVideo(path: String) = launchOpen(path, video = true, promptStartup = true) { sessions.openVideo(path, initialConfigBeside(path)) }

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

    /** Open a source from [source], which streams how it is going and ends with the session: shows that on the loading screen, then the sequence. */
    private fun launchOpen(path: String, video: Boolean, promptStartup: Boolean = false, source: () -> Flow<OpenProgress>) {
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
                val opened = info ?: run { fail(if (video) "video import produced no session" else "opening produced no session"); return@launch }
                if (_screen.value !is AppScreen.Opening) {
                    // Cancelled just as it finished: the daemon has a session nobody here will use.
                    withContext(NonCancellable) { runCatching { engine.client?.closeSession(opened.sessionId) } }
                    return@launch
                }
                sessions.applySessionInfo(opened)
                onOpened(path, opened, promptStartup = promptStartup)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Throwable) {
                fail(e.message ?: if (video) "failed to import video" else "failed to open")
            }
        }
    }

    fun closeSession() {
        scope.launch {
            closeOpenSession()
            lastResumePath = null // nothing is open, so a crash from here on has nothing to resume
            _screen.value = AppScreen.Initial
        }
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
        currentSequence?.close()
        currentSequence = null
        sessionScope?.cancel()
        sessionScope = null

        _showPreRenderPrompt.value = false
        _showPostRenderPrompt.value = false
        autoRenderAfterProcessing = false
        awaitingProcessingPrompt = false
        _showSettings.value = false
        _sequenceProgress.value = null
        _showRenderVideo.value = false
        _renderVideoAutoStart.value = false
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
        scope.launch {
            restarting = true
            _engineDown.value = null
            _screen.value = AppScreen.Loading("Restarting engine", null, null)
            val ok = engine.restart()
            restarting = false
            if (!ok) {
                _screen.value = AppScreen.Initial
                showEngineDown()
                return@launch
            }
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

    private fun onOpened(path: String, info: SessionInfo, addToRecent: Boolean = true, promptStartup: Boolean = false) {
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
                    "cancelled", "error" -> {
                        awaitingProcessingPrompt = false
                        autoRenderAfterProcessing = false
                    }
                }
            }
        }
        sessionScope.launch { proc.errors.collect(::report) }
        val svm = SequenceViewModel(sessionScope, info, frameRepo, proc, outlierRepo, imageCache, export, horizonRepo, onError = ::report, prefs = prefs)
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
            "startup" -> _startupStep.value = StartupStep.HORIZON // dev hook: startup prompts
            "removal" -> _startupStep.value = StartupStep.REMOVAL // dev hook: the last startup prompt
            "progress" -> showSequenceProgress(svm) // dev hook: screenshot the reopened-sequence panel
            else -> Unit
        }
        autoFrame?.let { svm.setCurrentIndex(it) }
        svm.openOutlierWindow = { _showOutlierWindow.value = true }
        currentSequence = svm
        _screen.value = AppScreen.Sequence(svm)
        // Fresh source → walk the startup prompts (skipped for config resume + dev auto-open hooks).
        if (promptStartup && autoMode == null) {
            _startupStep.value = StartupStep.HORIZON
        } else if (autoMode == null) {
            // A config resume. Normally there is nothing to prompt for — the config already
            // carries the answers. The exception is a hand-painted horizon selection the last
            // session never finished, which has to come before processing rather than after.
            // The panel waits for that: a run started now would fall back to the automatic horizon detection they had declined.
            if (!resumeStartupHorizonIfUnfinished(svm, info.config)) showSequenceProgress(svm)
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
