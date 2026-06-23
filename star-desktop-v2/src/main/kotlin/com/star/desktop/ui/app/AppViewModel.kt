package com.star.desktop.ui.app

import com.star.desktop.data.FrameRepository
import com.star.desktop.data.ImageCache
import com.star.desktop.data.LocalPreferences
import com.star.desktop.data.OutlierRepository
import com.star.desktop.data.ProcessingRepository
import com.star.desktop.data.SessionRepository
import com.star.desktop.engine.EngineState
import com.star.desktop.engine.EngineStatus
import com.star.desktop.ui.sequence.SequenceViewModel
import com.star.desktop.util.Log
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

    private val _recentFiles = MutableStateFlow(prefs.recentFiles)
    val recentFiles: StateFlow<List<String>> = _recentFiles.asStateFlow()

    val export = com.star.desktop.data.ExportRepository { engine.client }

    private val _showSettings = MutableStateFlow(false)
    val showSettings: StateFlow<Boolean> = _showSettings.asStateFlow()
    fun openSettings() { _showSettings.value = true }
    fun closeSettings() { _showSettings.value = false }

    private val _showRenderVideo = MutableStateFlow(false)
    val showRenderVideo: StateFlow<Boolean> = _showRenderVideo.asStateFlow()
    fun openRenderVideo() { _showRenderVideo.value = true }
    fun closeRenderVideo() { _showRenderVideo.value = false }

    private val _showOutlierWindow = MutableStateFlow(false)
    val showOutlierWindow: StateFlow<Boolean> = _showOutlierWindow.asStateFlow()
    fun toggleOutlierWindow() { _showOutlierWindow.value = !_showOutlierWindow.value }
    fun closeOutlierWindow() { _showOutlierWindow.value = false }

    private val _showAlignmentWindow = MutableStateFlow(false)
    val showAlignmentWindow: StateFlow<Boolean> = _showAlignmentWindow.asStateFlow()
    fun toggleAlignmentWindow() { _showAlignmentWindow.value = !_showAlignmentWindow.value }
    fun closeAlignmentWindow() { _showAlignmentWindow.value = false }

    init {
        scope.launch { engine.start() }
        scope.launch {
            engine.status.collect { st ->
                if (st is EngineStatus.Failed && _screen.value is AppScreen.Sequence) {
                    currentSequence?.close()
                    currentSequence = null
                    sessions.clearLocal()
                    _error.value = "Engine stopped: ${st.message}"
                    _screen.value = AppScreen.Initial
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

    fun openSequence(dir: String) = launchOpen("Opening image sequence", dir) { sessions.openSequence(dir) }

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
                    onOpened(path, finalInfo)
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

    fun removeRecent(path: String) {
        prefs.removeRecentFile(path)
        _recentFiles.value = prefs.recentFiles
    }

    suspend fun shutdown() = engine.shutdown()

    private fun launchOpen(title: String, path: String, block: suspend () -> SessionInfo) {
        scope.launch {
            ensureConnected()
            _screen.value = AppScreen.Loading(title, path, null)
            try {
                onOpened(path, block())
            } catch (e: Throwable) {
                fail(e.message ?: "failed to open")
            }
        }
    }

    private fun onOpened(path: String, info: SessionInfo) {
        prefs.addRecentFile(path)
        _recentFiles.value = prefs.recentFiles
        currentSequence?.close()
        val proc = ProcessingRepository(scope) { engine.client }
        val svm = SequenceViewModel(scope, info, frameRepo, proc, outlierRepo, imageCache)
        when (autoMode) {
            "edit" -> svm.setMode(com.star.desktop.domain.InteractionMode.EDIT)
            "grid" -> svm.setMode(com.star.desktop.domain.InteractionMode.GRID)
            "align" -> toggleAlignmentWindow()
            "horizon" -> { svm.setMode(com.star.desktop.domain.InteractionMode.EDIT); svm.toggleHorizonPaint() }
            else -> Unit
        }
        autoFrame?.let { svm.setCurrentIndex(it) }
        currentSequence = svm
        _screen.value = AppScreen.Sequence(svm)
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
