package com.star.desktop.ui.windows

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.star.desktop.i18n.localized
import com.star.desktop.ui.app.DebugLogSettings
import com.star.desktop.ui.theme.StarColors
import com.star.desktop.ui.theme.StarShapes
import com.star.desktop.util.Log
import com.star.desktop.util.LogBuffer
import com.star.desktop.util.LogLine
import kotlinx.coroutines.delay

/**
 * The Debug window (macOS `DebugView`, Window ▸ Debug Window): the log as it is written, by this client and by the engine. What it shows is
 * everything at or above the *Show* level; the *Log Level* is how much is logged at all (and is sent to the engine); the file switch also
 * writes a log file, at its own level, from each process. It keeps up with the log while it is scrolled to the bottom, and lets go when
 * the user scrolls up to read; Scroll to Bottom takes it up again.
 */
@OptIn(ExperimentalLayoutApi::class)
@Composable
fun DebugWindowView(settings: DebugLogSettings, engineLogPath: String) {
    val level by settings.level.collectAsState()
    val fileEnabled by settings.fileEnabled.collectAsState()
    val fileLevel by settings.fileLevel.collectAsState()
    val clientFile by settings.clientFile.collectAsState()
    val engineFile by settings.engineFile.collectAsState()

    // macOS shows warnings and errors until told otherwise.
    var show by remember { mutableStateOf(Log.Level.WARN) }
    var version by remember { mutableStateOf(LogBuffer.version) }
    LaunchedEffect(Unit) {
        while (true) {
            delay(200)   // a verbose engine writes many lines a second; the window follows at a pace the eye can
            if (LogBuffer.version != version) version = LogBuffer.version
        }
    }
    val lines = remember(version, show) { LogBuffer.snapshot().filter { it.level.ordinal >= show.ordinal } }

    val listState = rememberLazyListState()
    var follow by remember { mutableStateOf(true) }
    LaunchedEffect(listState) {
        snapshotFlow { listState.isScrollInProgress }.collect { scrolling -> if (!scrolling) follow = !listState.canScrollForward }
    }
    LaunchedEffect(lines.size, version, follow) {
        if (follow && lines.isNotEmpty()) listState.scrollToItem(lines.lastIndex)
    }

    val clipboard = LocalClipboardManager.current

    Column(Modifier.fillMaxSize().background(StarColors.appBackground).padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        FlowRow(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalArrangement = Arrangement.spacedBy(6.dp, Alignment.CenterVertically)) {
            LevelPicker(localized("ui.log_level"), level, onSelect = settings::setLevel)
            LevelPicker(localized("ui.show"), show, onSelect = { show = it })
            Text(localized("ui.max_log_lines"), color = StarColors.textSecondary, fontSize = 12.sp)
            MaxLinesField()
            OutlinedButton(onClick = { clipboard.setText(AnnotatedString(LogBuffer.rawText())) }) { Text(localized("ui.copy_to_clipboard"), fontSize = 12.sp) }
            OutlinedButton(
                onClick = { follow = true },
                enabled = !follow,
            ) { Text(localized("ui.scroll_to_bottom"), fontSize = 12.sp) }
            OutlinedButton(onClick = { LogBuffer.clear(); version = LogBuffer.version }) { Text(localized("ui.clear"), fontSize = 12.sp) }
            Switch(checked = fileEnabled, onCheckedChange = settings::setFileEnabled)
            LevelPicker(localized("ui.log_to_file_at_level"), fileLevel, enabled = fileEnabled, onSelect = settings::setFileLevel)
        }

        // Where the logs are kept: the engine's always, and a file of each process's own when the switch is on.
        Column {
            Text(localized("ui.debug_engine_log", engineLogPath), color = StarColors.textDisabled, fontSize = 11.sp)
            clientFile?.let { Text(localized("ui.debug_log_file", it.absolutePath), color = StarColors.textDisabled, fontSize = 11.sp) }
            engineFile?.let { Text(localized("ui.debug_log_file", it), color = StarColors.textDisabled, fontSize = 11.sp) }
        }

        SelectionContainer(Modifier.weight(1f).fillMaxWidth()) {
            LazyColumn(Modifier.fillMaxSize(), state = listState) {
                items(lines) { LogRow(it) }
            }
        }
    }
}

@Composable
private fun LogRow(line: LogLine) {
    val color = when (line.level) {
        Log.Level.ERROR -> StarColors.red
        Log.Level.WARN -> StarColors.yellow
        Log.Level.VERBOSE, Log.Level.DEBUG -> StarColors.textDisabled
        Log.Level.INFO -> StarColors.textPrimary
    }
    Text(line.text(), color = color, fontSize = 11.sp, fontFamily = FontFamily.Monospace)
}

/**
 * The log-to-file switch and its level, as the macOS right panel has them (the Debug window has the same two among its controls): a log file is
 * written by this client, and by the engine, at the level chosen.
 */
@Composable
fun LogToFileControls(settings: DebugLogSettings) {
    val on by settings.fileEnabled.collectAsState()
    val level by settings.fileLevel.collectAsState()
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        Switch(checked = on, onCheckedChange = settings::setFileEnabled)
        Text(localized("ui.log_to_file_at_level_2"), color = if (on) StarColors.green else StarColors.white, fontSize = 11.sp)
    }
    LevelPicker("", level, enabled = on, onSelect = settings::setFileLevel)
}

/** A label and a menu of the levels, each with its emoji and name as macOS shows them. */
@Composable
private fun LevelPicker(label: String, selected: Log.Level, enabled: Boolean = true, onSelect: (Log.Level) -> Unit) {
    var expanded by remember { mutableStateOf(false) }
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        if (label.isNotEmpty()) Text(label, color = if (enabled) StarColors.textSecondary else StarColors.textDisabled, fontSize = 12.sp)
        Box {
            Box(
                Modifier
                    .clip(StarShapes.picker)
                    .background(StarColors.cellDefault)
                    .clickable(enabled = enabled) { expanded = true }
                    .padding(horizontal = 10.dp, vertical = 6.dp),
            ) {
                Text("${selected.emoji} ${selected.word}", color = if (enabled) StarColors.textPrimary else StarColors.textDisabled, fontSize = 12.sp)
            }
            DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
                Log.Level.entries.forEach { option ->
                    DropdownMenuItem(
                        text = { Text("${option.emoji} ${option.word}", color = if (option == selected) StarColors.accent else StarColors.textPrimary, fontSize = 12.sp) },
                        onClick = { onSelect(option); expanded = false },
                    )
                }
            }
        }
    }
}

/** How many lines are kept: digits only, applied on Return or on leaving the box, and put back to what is in force if it is not a number. */
@Composable
private fun MaxLinesField() {
    var text by remember { mutableStateOf(LogBuffer.maxLines.toString()) }
    fun commit() {
        text.toIntOrNull()?.takeIf { it > 0 }?.let { LogBuffer.maxLines = it }
        text = LogBuffer.maxLines.toString()
    }
    BasicTextField(
        value = text,
        onValueChange = { text = it.filter(Char::isDigit) },
        singleLine = true,
        textStyle = TextStyle(color = StarColors.white, fontSize = 12.sp),
        cursorBrush = SolidColor(Color.White),
        modifier = Modifier
            .width(80.dp)
            .background(StarColors.sidePanel)
            .padding(horizontal = 6.dp, vertical = 5.dp)
            .onFocusChanged { if (!it.isFocused) commit() }
            .onPreviewKeyEvent { e ->
                if (e.type == KeyEventType.KeyDown && (e.key == Key.Enter || e.key == Key.NumPadEnter)) { commit(); true } else false
            },
    )
}
