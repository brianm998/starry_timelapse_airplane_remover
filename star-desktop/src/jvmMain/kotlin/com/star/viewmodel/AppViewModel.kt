package com.star.viewmodel

import com.star.data.*
import com.star.engine.*
import com.star.proto.SessionInfo
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*

/** Three-mode interaction model matching ContentView.swift / ViewModel.swift. */
enum class InteractionMode { Edit, Scrub, Grid }

/**
 * Root application state.
 * Mirrors ViewModel.swift — owns engine lifecycle, session opening, and mode.
 */
class AppViewModel(
    private val engine: EngineState,
    val prefs: LocalPreferences,
) {
    val scope = CoroutineScope(Dispatchers.Default + SupervisorJob())

    val engineStatus: StateFlow<EngineStatus> = engine.status

    private val _interactionMode = MutableStateFlow(InteractionMode.Edit)
    val interactionMode: StateFlow<InteractionMode> = _interactionMode.asStateFlow()

    private val _showOutlierWindow = MutableStateFlow(false)
    val showOutlierWindow: StateFlow<Boolean> = _showOutlierWindow.asStateFlow()

    private val _showAlignmentWindow = MutableStateFlow(false)
    val showAlignmentWindow: StateFlow<Boolean> = _showAlignmentWindow.asStateFlow()

    // Active sequence view model; non-null when a session is open.
    private val _sequenceViewModel = MutableStateFlow<SequenceViewModel?>(null)
    val sequenceViewModel: StateFlow<SequenceViewModel?> = _sequenceViewModel.asStateFlow()

    private val _error = MutableStateFlow<String?>(null)
    val error: StateFlow<String?> = _error.asStateFlow()

    // ---- Engine lifecycle ----

    fun startEngine() {
        scope.launch {
            engine.start()
            // Surface engine errors to the UI.
            engine.status.collect { status ->
                if (status is EngineStatus.Failed) {
                    _error.value = "Engine stopped: ${status.message}"
                }
            }
        }
    }

    fun restartEngine() {
        scope.launch {
            _error.value = null
            engine.restart()
        }
    }

    // ---- Session opening ----

    suspend fun openSequence(dir: String) = openSession {
        val sessionRepo = SessionRepository(engine.client)
        val info = sessionRepo.openSequence(dir)
        buildSequenceViewModel(sessionRepo, info)
    }

    suspend fun openConfig(configPath: String) = openSession {
        val sessionRepo = SessionRepository(engine.client)
        val info = sessionRepo.openConfig(configPath)
        buildSequenceViewModel(sessionRepo, info)
    }

    fun openVideo(path: String) {
        scope.launch {
            val sessionRepo = SessionRepository(engine.client)
            sessionRepo.openVideo(path).collect { progress ->
                if (progress.hasDone()) {
                    val vm = buildSequenceViewModel(sessionRepo, progress.done)
                    _sequenceViewModel.value = vm
                }
            }
        }
    }

    private suspend fun openSession(block: suspend () -> SequenceViewModel) {
        try {
            _error.value = null
            closeCurrentSession()
            val vm = block()
            _sequenceViewModel.value = vm
            prefs.addRecentFile(vm.sessionInfo.config.outputPath.ifBlank {
                vm.sessionInfo.config.tempOutputPath
            })
        } catch (e: Exception) {
            _error.value = "Failed to open: ${e.message}"
        }
    }

    fun closeCurrentSession() {
        val existing = _sequenceViewModel.value ?: return
        scope.launch {
            existing.close()
            _sequenceViewModel.value = null
        }
    }

    // ---- Mode ----

    fun setMode(mode: InteractionMode) { _interactionMode.value = mode }

    fun toggleOutlierWindow() { _showOutlierWindow.value = !_showOutlierWindow.value }
    fun toggleAlignmentWindow() { _showAlignmentWindow.value = !_showAlignmentWindow.value }

    fun clearError() { _error.value = null }

    fun onCleared() { scope.cancel() }

    private fun buildSequenceViewModel(sessionRepo: SessionRepository, info: SessionInfo): SequenceViewModel {
        val frameRepo = FrameRepository(engine.client)
        val outlierRepo = OutlierRepository(engine.client)
        val exportRepo = ExportRepository(engine.client)
        val imageCache = ImageCache()
        val processingRepo = ProcessingRepository(engine.client)
        return SequenceViewModel(
            sessionRepo = sessionRepo,
            frameRepo = frameRepo,
            outlierRepo = outlierRepo,
            exportRepo = exportRepo,
            processingRepo = processingRepo,
            imageCache = imageCache,
            initialInfo = info,
            parentScope = scope,
        )
    }
}
