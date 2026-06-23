package com.star.desktop.data

import com.star.desktop.engine.StarClient
import com.star.desktop.engine.StarRpcException
import com.star.desktop.util.Log
import com.star.proto.FrameProcessingState
import com.star.proto.ProgressEvent
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

/**
 * Owns the single long-lived `Processing.StreamProgress` subscription for one session and folds
 * **every** `ProgressEvent` arm into observable state (the v1 client dropped most arms).
 *
 * Ordering rule (the v1 "barely works" bug): the daemon attaches its progress continuation only when
 * the stream RPC arrives, so [subscribe] must run and be live *before* [start] — otherwise early
 * events are lost. [start] does not begin the subscription; it assumes one is already open.
 *
 * The daemon has a single progress slot per session shared with the `Export.*` streams, so only one
 * progress-bearing stream may run at a time — keep this subscription and serialize exports against it.
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

    /** Per-frame saving state (0..3) from `frame_saving_state`. */
    private val _savingState = MutableStateFlow<Map<Int, Int>>(emptyMap())
    val savingState: StateFlow<Map<Int, Int>> = _savingState.asStateFlow()

    data class Io(val current: Int, val total: Int, val outputDir: String)
    private val _ioProgress = MutableStateFlow<Io?>(null)
    val ioProgress: StateFlow<Io?> = _ioProgress.asStateFlow()

    private val _sequenceState = MutableStateFlow<String?>(null)
    val sequenceState: StateFlow<String?> = _sequenceState.asStateFlow()

    private val _processing = MutableStateFlow(false)
    val processing: StateFlow<Boolean> = _processing.asStateFlow()

    private var subJob: Job? = null

    private fun c(): StarClient = clientProvider() ?: throw StarRpcException(-1, "engine not connected")

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

    suspend fun start(sessionId: String, startIndex: Int = 0, endIndex: Int = -1) {
        _sequenceState.value = null
        _processing.value = true
        try {
            c().startProcessing(sessionId, startIndex, endIndex)
        } catch (e: Throwable) {
            _processing.value = false
            throw e
        }
    }

    suspend fun cancel(sessionId: String) {
        runCatching { c().cancelProcessing(sessionId) }
        _processing.value = false
    }

    /** Tear down the subscription (session close). */
    fun stop() {
        subJob?.cancel()
        subJob = null
    }

    fun frameState(index: Int): FrameProcessingState? = _frameStates.value[index]

    private fun fold(ev: ProgressEvent) {
        when (ev.kindCase) {
            ProgressEvent.KindCase.FRAME_STATE ->
                _frameStates.update { it + (ev.frameState.frameIndex to ev.frameState.state) }
            ProgressEvent.KindCase.FRAME_SAVING_STATE ->
                _savingState.update { it + (ev.frameSavingState.frameIndex to ev.frameSavingState.newState) }
            ProgressEvent.KindCase.OUTLIERS_LOADED ->
                _outlierLoadState.update { it + (ev.outliersLoaded.frameIndex to ev.outliersLoaded.state) }
            ProgressEvent.KindCase.IO_PROGRESS ->
                _ioProgress.value = ev.ioProgress.let { Io(it.current, it.total, it.outputDir) }
            ProgressEvent.KindCase.SEQUENCE_STATE -> {
                val s = ev.sequenceState.state
                _sequenceState.value = s
                if (s == "done") _processing.value = false
            }
            ProgressEvent.KindCase.FRAME_EXISTING ->
                Log.d("Processing") { "frame ${ev.frameExisting} already exists" }
            else -> Unit
        }
    }
}
