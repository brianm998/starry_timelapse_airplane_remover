package com.star.desktop.data

import com.star.desktop.i18n.localized
import com.star.desktop.engine.StarClient
import com.star.desktop.engine.StarRpcException
import com.star.desktop.util.Log
import com.star.proto.FrameProcessingState
import com.star.proto.ProgressEvent
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.flow.updateAndGet
import kotlinx.coroutines.launch

/**
 * Owns the single long-lived `Processing.StreamProgress` subscription for one session and folds
 * **every** `ProgressEvent` arm into observable state (the v1 client dropped most arms).
 *
 * Ordering rule (the v1 "barely works" bug): the daemon attaches its progress continuation only when
 * the stream RPC arrives, so [subscribe] must run and be live *before* [start] — otherwise early
 * events are lost. [start] does not begin the subscription; it assumes one is already open.
 *
 * The daemon keeps a set of progress subscribers per session, and `Export.RenderSequence` /
 * `Horizon.Reprocess` are subscribers of their own for their duration, so this subscription is
 * never torn down to make room for them. Call [stop] only when the session closes.
 */
class ProcessingRepository(
    private val scope: CoroutineScope,
    private val clientProvider: () -> StarClient?,
) {
    private val _frameStates = MutableStateFlow<Map<Int, FrameProcessingState>>(emptyMap())
    val frameStates: StateFlow<Map<Int, FrameProcessingState>> = _frameStates.asStateFlow()

    /** Per-frame outlier loading state (0=unloaded, 1=loading, 2=loaded) from `outliers_loaded`. */
    private val _outlierLoadState = MutableStateFlow<Map<Int, Int>>(emptyMap())
    val outlierLoadState: StateFlow<Map<Int, Int>> = _outlierLoadState.asStateFlow()

    /** Per-frame saving state from `frame_saving_state`: 0 not saving, 1 in purgatory, 2 save pending, 3 saving. */
    private val _savingState = MutableStateFlow<Map<Int, Int>>(emptyMap())
    val savingState: StateFlow<Map<Int, Int>> = _savingState.asStateFlow()

    /**
     * How many frames have edits that are not written to disk yet (in purgatory, waiting, or being
     * saved). Closing the session or quitting with this above zero is losing work unless the daemon
     * is given the chance to finish — see the "work in progress" check.
     */
    private val _pendingSaves = MutableStateFlow(0)
    val pendingSaves: StateFlow<Int> = _pendingSaves.asStateFlow()

    /** A preview of a frame was written (`image_saved`): whatever a client holds of it is out of date. */
    data class ImageSaved(val frameIndex: Int, val viewMode: com.star.proto.FrameViewMode)
    private val _imageSaved = MutableSharedFlow<ImageSaved>(extraBufferCapacity = 256)
    val imageSaved: SharedFlow<ImageSaved> = _imageSaved.asSharedFlow()

    data class Io(val current: Int, val total: Int, val outputDir: String)
    private val _ioProgress = MutableStateFlow<Io?>(null)
    val ioProgress: StateFlow<Io?> = _ioProgress.asStateFlow()

    private val _sequenceState = MutableStateFlow<String?>(null)
    val sequenceState: StateFlow<String?> = _sequenceState.asStateFlow()

    private val _processing = MutableStateFlow(false)
    val processing: StateFlow<Boolean> = _processing.asStateFlow()

    /**
     * How far each step of the run in progress has got, as the daemon last reported it (`step_progress`); null before the first report
     * of a run. Cleared as a run starts, so the last run's bars are not shown as this one's.
     */
    private val _stepProgress = MutableStateFlow<com.star.proto.StepProgress?>(null)
    val stepProgress: StateFlow<com.star.proto.StepProgress?> = _stepProgress.asStateFlow()

    /**
     * A run that finished with failed operations (`sequence_state = "error"`): the failures, one per line.
     * One-shot, not state — each is shown to the user once.
     */
    private val _errors = MutableSharedFlow<String>(extraBufferCapacity = 8)
    val errors: SharedFlow<String> = _errors.asSharedFlow()

    /**
     * How far the extraction of the video's frames has got, as the daemon last said (`frame_extraction`); null for an image sequence.
     * Complete when everything is out, which is when the progress bar goes away.
     */
    private val _extraction = MutableStateFlow<com.star.proto.FrameExtraction?>(null)
    val extraction: StateFlow<com.star.proto.FrameExtraction?> = _extraction.asStateFlow()

    /**
     * The frames that are extracted, while a video is still being extracted; null when every frame is there (an image sequence, or a video
     * that is done), so nothing has to be asked of a set that would be everything.
     */
    private val _extractedFrames = MutableStateFlow<com.star.desktop.domain.ExtractedFrames?>(null)
    val extractedFrames: StateFlow<com.star.desktop.domain.ExtractedFrames?> = _extractedFrames.asStateFlow()

    /** Start from what `SessionInfo.extraction` said at open: the live events carry on from it. */
    fun seedExtraction(initial: com.star.proto.FrameExtraction?) {
        if (initial == null || !initial.active || initial.complete) return
        applyExtraction(initial)
    }

    private fun applyExtraction(e: com.star.proto.FrameExtraction) {
        _extraction.value = e
        if (e.complete) {
            _extractedFrames.value = null
        } else if (e.availableCount > 0) {
            // a snapshot lists every range: it replaces what there was
            _extractedFrames.value = com.star.desktop.domain.ExtractedFrames.fromProto(e.availableList)
        } else if (_extractedFrames.value == null) {
            _extractedFrames.value = com.star.desktop.domain.ExtractedFrames.NONE
        }
    }

    private var subJob: Job? = null

    /**
     * Whether a run was started since the last [cancel]. The daemon's `cancelled` event for that
     * stop can reach us after the user has already started the next run, and is not about that run.
     */
    private var startedSinceCancel = false

    private fun c(): StarClient = clientProvider() ?: throw StarRpcException(-1, localized("ui.engine_not_connected"))

    /** Open the persistent progress subscription. Call once at session open, before [start]. */
    fun subscribe(sessionId: String) {
        subJob?.cancel()
        subJob = scope.launch {
            try {
                c().streamProgress(sessionId).collect(::fold)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Throwable) {
                Log.w("Processing") { "progress stream ended: ${e.message}" }
            }
        }
    }

    suspend fun start(sessionId: String, startIndex: Int = 0, endIndex: Int = -1, force: Boolean = false) {
        _sequenceState.value = null
        _stepProgress.value = null
        _processing.value = true
        startedSinceCancel = true
        try {
            c().startProcessing(sessionId, startIndex, endIndex, force)
        } catch (e: Throwable) {
            _processing.value = false
            throw e
        }
    }

    /**
     * Stop the run in progress and start it again over the same range under the settings as they now are, as one step: the daemon waits for the
     * stop, and does not announce it, so to anything watching this is the run going on rather than one cancelled and another begun.
     */
    suspend fun restart(sessionId: String, startIndex: Int = 0, endIndex: Int = -1) {
        _sequenceState.value = null
        _stepProgress.value = null
        _processing.value = true
        startedSinceCancel = true
        try {
            c().restartProcessing(sessionId, startIndex, endIndex)
        } catch (e: Throwable) {
            _processing.value = false
            throw e
        }
    }

    /**
     * Stop the run. The daemon answers once what was running has stopped, which can take a while, so
     * the UI goes idle at once rather than after the answer.
     */
    suspend fun cancel(sessionId: String) {
        startedSinceCancel = false
        _processing.value = false
        runCatching { c().cancelProcessing(sessionId) }
    }

    /** Granular reprocess of selected frames; progress arrives over the live StreamProgress subscription. */
    suspend fun reprocessFrames(sessionId: String, indices: List<Int>, type: com.star.proto.ReprocessingType) {
        if (indices.isEmpty()) return
        _sequenceState.value = null
        _stepProgress.value = null
        _processing.value = true
        startedSinceCancel = true
        try {
            c().reprocessFrames(sessionId, indices, type)
        } catch (e: Throwable) {
            _processing.value = false
            throw e
        }
    }

    /**
     * Start a run the daemon claims some other way than `Processing.Start` (a horizon refinement): [start] asks for it and
     * says whether one began. Until it does, and for the length of it, this is a run like any other. When none began (there was nothing to
     * refine, or the daemon is already running one and will not start two) what was showing is put back: a refused start used to clear the
     * busy flag, and the step bars, of the run that was still going (L9).
     */
    suspend fun startClaimedRun(start: suspend () -> Boolean) {
        val before = Triple(_sequenceState.value, _stepProgress.value, _processing.value)
        val startedBefore = startedSinceCancel
        fun putBack() {
            _sequenceState.value = before.first
            _stepProgress.value = before.second
            _processing.value = before.third
            startedSinceCancel = startedBefore
        }
        _sequenceState.value = null
        _stepProgress.value = null
        _processing.value = true
        startedSinceCancel = true
        val started = try {
            start()
        } catch (e: Throwable) {
            putBack()
            throw e
        }
        if (!started) putBack()
    }

    /** A frame's horizon lines changed: a mask written or deleted, a reference painted or cleared, a refinement finished (`horizon_updated`). */
    private val _horizonUpdated = MutableSharedFlow<Int>(extraBufferCapacity = 512)
    val horizonUpdated: SharedFlow<Int> = _horizonUpdated.asSharedFlow()

    /** Tear down the subscription (session close). */
    fun stop() {
        subJob?.cancel()
        subJob = null
    }

    fun frameState(index: Int): FrameProcessingState? = _frameStates.value[index]

    internal fun fold(ev: ProgressEvent) {
        when (ev.kindCase) {
            ProgressEvent.KindCase.FRAME_STATE ->
                _frameStates.update { it + (ev.frameState.frameIndex to ev.frameState.state) }
            ProgressEvent.KindCase.FRAME_SAVING_STATE -> {
                val states = _savingState.updateAndGet { it + (ev.frameSavingState.frameIndex to ev.frameSavingState.newState) }
                _pendingSaves.value = states.count { it.value != SAVING_NOT_SAVING }
            }
            ProgressEvent.KindCase.OUTLIERS_LOADED ->
                _outlierLoadState.update { it + (ev.outliersLoaded.frameIndex to ev.outliersLoaded.state) }
            ProgressEvent.KindCase.IO_PROGRESS ->
                _ioProgress.value = ev.ioProgress.let { Io(it.current, it.total, it.outputDir) }
            ProgressEvent.KindCase.SEQUENCE_STATE -> {
                val s = ev.sequenceState.state
                // The stop's own `cancelled`, arriving after the next run was started: it is not
                // about that run.
                if (s == "cancelled" && startedSinceCancel) return
                _sequenceState.value = s
                if (s == "done" || s == "cancelled" || s == "error") _processing.value = false
                if (s == "error") _errors.tryEmit(ev.sequenceState.message.ifBlank { s })
            }
            ProgressEvent.KindCase.HORIZON_UPDATED -> _horizonUpdated.tryEmit(ev.horizonUpdated)
            ProgressEvent.KindCase.STEP_PROGRESS -> _stepProgress.value = ev.stepProgress
            ProgressEvent.KindCase.FRAME_EXTRACTION -> applyExtraction(ev.frameExtraction)
            ProgressEvent.KindCase.FRAMES_AVAILABLE -> {
                val now = _extractedFrames.value
                if (now != null) {
                    _extractedFrames.value = now + ev.framesAvailable.rangesList.map { it.start until it.end }
                }
            }
            ProgressEvent.KindCase.IMAGE_SAVED ->
                _imageSaved.tryEmit(ImageSaved(ev.imageSaved.frameIndex, ev.imageSaved.viewMode))
            ProgressEvent.KindCase.FRAME_EXISTING ->
                Log.d("Processing") { "frame ${ev.frameExisting} already exists" }
            else -> Unit
        }
    }

    private companion object {
        /** `FrameSavingState.notSaving` in the daemon's `frame_saving_state` events. */
        const val SAVING_NOT_SAVING = 0
    }
}
