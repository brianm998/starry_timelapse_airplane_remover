package com.star.viewmodel

import com.star.data.*
import com.star.proto.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*

/**
 * Owns the open session: frame count, per-frame state grid, current frame, processing state.
 * Mirrors ImageSequenceViewModel.swift.
 */
class SequenceViewModel(
    val sessionRepo: SessionRepository,
    val frameRepo: FrameRepository,
    val outlierRepo: OutlierRepository,
    val exportRepo: ExportRepository,
    val processingRepo: ProcessingRepository,
    val imageCache: ImageCache,
    initialInfo: SessionInfo,
    parentScope: CoroutineScope,
) {
    val scope = CoroutineScope(Dispatchers.Default + SupervisorJob(parentScope.coroutineContext.job))

    private val _sessionInfo = MutableStateFlow(initialInfo)
    val sessionInfo: SessionInfo get() = _sessionInfo.value

    val sessionId: String get() = sessionInfo.sessionId
    val frameCount: Int get() = sessionInfo.frameCount

    private val _currentFrameIndex = MutableStateFlow(0)
    val currentFrameIndex: StateFlow<Int> = _currentFrameIndex.asStateFlow()

    // Per-frame states from StreamProgress (frameIndex → FrameProcessingState)
    val frameStates: StateFlow<Map<Int, FrameProcessingState>> = processingRepo.frameStates
    val processingStatus: StateFlow<ProcessingStatus> = processingRepo.processingStatus
    val ioProgress: StateFlow<IoProgress?> = processingRepo.ioProgress

    // Current frame view model
    private val _frameViewModel = MutableStateFlow<FrameViewModel?>(null)
    val frameViewModel: StateFlow<FrameViewModel?> = _frameViewModel.asStateFlow()

    private val _config = MutableStateFlow(initialInfo.config)
    val config: StateFlow<Config> = _config.asStateFlow()

    private val _error = MutableStateFlow<String?>(null)
    val error: StateFlow<String?> = _error.asStateFlow()

    // ---- Frame navigation ----

    fun goToFrame(index: Int) {
        val clamped = index.coerceIn(0, frameCount - 1)
        if (_currentFrameIndex.value == clamped) return
        _currentFrameIndex.value = clamped
        loadCurrentFrame()
    }

    fun nextFrame() = goToFrame(_currentFrameIndex.value + 1)
    fun prevFrame() = goToFrame(_currentFrameIndex.value - 1)

    fun loadCurrentFrame() {
        val idx = _currentFrameIndex.value
        val existing = _frameViewModel.value
        println("[SequenceVM] loadCurrentFrame idx=$idx existing=${existing?.frameIndex}")
        if (existing?.frameIndex == idx) return
        val vm = FrameViewModel(
            sessionId = sessionId,
            frameIndex = idx,
            frameRepo = frameRepo,
            outlierRepo = outlierRepo,
            imageCache = imageCache,
            parentScope = scope,
        )
        _frameViewModel.value = vm
        vm.load()
    }

    init { loadCurrentFrame() }

    // ---- Processing ----

    fun processAll() {
        scope.launch {
            try {
                processingRepo.start(sessionId, 0, -1, scope)
            } catch (e: Exception) {
                _error.value = "Processing error: ${e.message}"
            }
        }
    }

    fun processRemaining() {
        scope.launch {
            // Find first unprocessed frame.
            val states = frameStates.value
            val firstUnprocessed = (0 until frameCount).firstOrNull { idx ->
                states[idx] != FrameProcessingState.FPS_COMPLETE
            } ?: return@launch
            try {
                processingRepo.start(sessionId, firstUnprocessed, -1, scope)
            } catch (e: Exception) {
                _error.value = "Processing error: ${e.message}"
            }
        }
    }

    fun processCurrentFrame(force: Boolean = false) {
        val idx = _currentFrameIndex.value
        scope.launch {
            try {
                processingRepo.start(sessionId, idx, idx + 1, scope)
            } catch (e: Exception) {
                _error.value = "Processing error: ${e.message}"
            }
        }
    }

    fun cancelProcessing() {
        scope.launch { processingRepo.cancel(sessionId) }
    }

    // ---- Config ----

    fun updateConfig(config: Config) {
        scope.launch {
            try {
                val updated = sessionRepo.updateConfig(config)
                _config.value = updated
            } catch (e: Exception) {
                _error.value = "Config update failed: ${e.message}"
            }
        }
    }

    // ---- Export ----

    fun renderSequence(onProgress: (ProgressEvent) -> Unit, onComplete: () -> Unit, onError: (String) -> Unit) {
        scope.launch {
            try {
                exportRepo.renderSequence(sessionId).collect(onProgress)
                onComplete()
            } catch (e: Exception) {
                onError(e.message ?: "render error")
            }
        }
    }

    fun exportVideo(
        outputPath: String,
        settings: VideoEncodeSettings,
        onProgress: (ProgressEvent) -> Unit,
        onComplete: () -> Unit,
        onError: (String) -> Unit,
    ) {
        scope.launch {
            try {
                exportRepo.exportVideo(sessionId, outputPath, settings).collect(onProgress)
                onComplete()
            } catch (e: Exception) {
                onError(e.message ?: "export error")
            }
        }
    }

    suspend fun close() {
        scope.cancel()
        imageCache.clear()
        sessionRepo.close()
    }
}
