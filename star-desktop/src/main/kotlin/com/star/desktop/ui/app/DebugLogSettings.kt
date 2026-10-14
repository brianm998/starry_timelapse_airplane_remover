package com.star.desktop.ui.app

import com.star.desktop.util.Log
import com.star.desktop.util.LogFile
import com.star.proto.SetLogLevelResponse
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import java.io.File

/**
 * What the Debug window sets (macOS `LoggingViewModel`): how much is logged, and whether a file is written as well. The two processes this app is
 * are one choice here: the client's own log and the engine's both follow the level, and both write a file of their own when asked; the window
 * shows the files' names.
 *
 * The engine is told as it is asked ([tellEngine] is `Daemon.SetLogLevel`; null when there is no engine to tell), and told again by
 * [reapplyToEngine] when a fresh one has started, since that begins at its own default.
 */
class DebugLogSettings(
    private val scope: CoroutineScope,
    private val tellEngine: suspend (level: String, fileEnabled: Boolean?, fileLevel: String) -> SetLogLevelResponse?,
    /** Where this client's log file goes. */
    private val logsDirectory: () -> File,
) {
    private val _level = MutableStateFlow(Log.level)
    /** What is shown in the window and logged to stderr by the client; what the engine writes to its stderr. */
    val level: StateFlow<Log.Level> = _level.asStateFlow()

    private val _fileEnabled = MutableStateFlow(false)
    val fileEnabled: StateFlow<Boolean> = _fileEnabled.asStateFlow()

    private val _fileLevel = MutableStateFlow(Log.Level.INFO)
    /** The level a log file is written at, which may be more verbose than the window shows. */
    val fileLevel: StateFlow<Log.Level> = _fileLevel.asStateFlow()

    private val _clientFile = MutableStateFlow<File?>(null)
    /** The file this client is writing its log to, or null. */
    val clientFile: StateFlow<File?> = _clientFile.asStateFlow()

    private val _engineFile = MutableStateFlow<String?>(null)
    /** The file the engine is writing its log to, or null. */
    val engineFile: StateFlow<String?> = _engineFile.asStateFlow()

    fun setLevel(level: Log.Level) {
        Log.level = level
        _level.value = level
        scope.launch { tellEngine(level.word, null, "") }
    }

    fun setFileEnabled(on: Boolean) {
        _fileEnabled.value = on
        if (on) _clientFile.value = LogFile.start(_fileLevel.value, logsDirectory()) else { LogFile.stop(); _clientFile.value = null }
        scope.launch { _engineFile.value = tellEngine("", on, _fileLevel.value.word)?.fileLogPath?.ifEmpty { null } }
    }

    fun setFileLevel(level: Log.Level) {
        _fileLevel.value = level
        LogFile.setLevel(level)
        scope.launch { _engineFile.value = tellEngine("", null, level.word)?.fileLogPath?.ifEmpty { null } ?: _engineFile.value }
    }

    /** A new engine has come up: it is at its own level and has no file, so what was chosen is said to it again. Nothing is sent if nothing was chosen. */
    fun reapplyToEngine() {
        if (_level.value == Log.Level.INFO && !_fileEnabled.value) return
        scope.launch {
            _engineFile.value = tellEngine(_level.value.word, if (_fileEnabled.value) true else null, _fileLevel.value.word)?.fileLogPath?.ifEmpty { null }
        }
    }
}
