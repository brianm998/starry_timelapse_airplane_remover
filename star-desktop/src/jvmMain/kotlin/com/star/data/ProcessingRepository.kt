package com.star.data

import com.star.engine.StarClient
import com.star.proto.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*

sealed class ProcessingStatus {
    data object Idle : ProcessingStatus()
    data object Running : ProcessingStatus()
    data object Cancelling : ProcessingStatus()
    data class Finished(val message: String = "") : ProcessingStatus()
    data class Error(val message: String) : ProcessingStatus()
}

/**
 * Manages Processing.Start / StreamProgress / Cancel.
 * Folds the ProgressEvent stream into per-frame state for the UI.
 */
class ProcessingRepository(private val client: StarClient) {

    private val _processingStatus = MutableStateFlow<ProcessingStatus>(ProcessingStatus.Idle)
    val processingStatus: StateFlow<ProcessingStatus> = _processingStatus.asStateFlow()

    // Per-frame state: frameIndex → FrameProcessingState ordinal
    private val _frameStates = MutableStateFlow<Map<Int, FrameProcessingState>>(emptyMap())
    val frameStates: StateFlow<Map<Int, FrameProcessingState>> = _frameStates.asStateFlow()

    private val _ioProgress = MutableStateFlow<IoProgress?>(null)
    val ioProgress: StateFlow<IoProgress?> = _ioProgress.asStateFlow()

    private var progressJob: Job? = null

    suspend fun start(
        sessionId: String,
        startIndex: Int = 0,
        endIndex: Int = -1,
        scope: CoroutineScope,
    ) {
        if (_processingStatus.value is ProcessingStatus.Running) return
        _processingStatus.value = ProcessingStatus.Running

        client.startProcessing(sessionId, startIndex, endIndex)

        progressJob = scope.launch {
            try {
                client.streamProgress(sessionId).collect { event ->
                    applyProgressEvent(event)
                }
                _processingStatus.value = ProcessingStatus.Finished()
            } catch (e: CancellationException) {
                _processingStatus.value = ProcessingStatus.Idle
                throw e
            } catch (e: Exception) {
                _processingStatus.value = ProcessingStatus.Error(e.message ?: "processing error")
            }
        }
    }

    suspend fun cancel(sessionId: String) {
        if (_processingStatus.value !is ProcessingStatus.Running) return
        _processingStatus.value = ProcessingStatus.Cancelling
        try {
            client.cancelProcessing(sessionId)
        } catch (_: Exception) { /* ignore */ }
        progressJob?.cancel()
        _processingStatus.value = ProcessingStatus.Idle
    }

    /** Subscribe to progress events for a render sequence operation. */
    fun renderSequenceProgress(sessionId: String): Flow<ProgressEvent> = client.renderSequence(sessionId)

    /** Subscribe to progress events for a video export operation. */
    fun exportVideoProgress(
        sessionId: String,
        outputPath: String = "",
        settings: VideoEncodeSettings = VideoEncodeSettings.getDefaultInstance(),
    ): Flow<ProgressEvent> = client.exportVideo(sessionId, outputPath, settings)

    private fun applyProgressEvent(event: ProgressEvent) {
        when (event.kindCase) {
            ProgressEvent.KindCase.FRAME_STATE -> {
                val fs = event.frameState
                _frameStates.value = _frameStates.value + (fs.frameIndex to fs.state)
            }
            ProgressEvent.KindCase.IO_PROGRESS -> {
                _ioProgress.value = event.ioProgress
            }
            ProgressEvent.KindCase.SEQUENCE_STATE -> Unit // handled by caller if needed
            else -> Unit
        }
    }

    fun resetFrameStates() {
        _frameStates.value = emptyMap()
        _ioProgress.value = null
    }
}
