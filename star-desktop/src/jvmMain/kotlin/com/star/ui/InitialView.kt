package com.star.ui

import androidx.compose.foundation.*
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.*
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.*
import com.star.data.LocalPreferences
import com.star.engine.EngineStatus
import com.star.ui.theme.StarColors
import java.awt.FileDialog
import java.io.File

/**
 * Startup screen — mirrors StartupView.swift + InitialView.swift.
 * Shows: engine status, drag-drop target, recent files list.
 */
@Composable
fun InitialView(
    prefs: LocalPreferences,
    engineStatus: EngineStatus,
    onOpenSequence: (String) -> Unit,
    onOpenConfig: (String) -> Unit,
    onOpenVideo: (String) -> Unit,
    onRestartEngine: () -> Unit,
) {
    Column(
        Modifier.fillMaxSize().background(StarColors.panelBackground),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Spacer(Modifier.height(40.dp))

        // App title
        Text(
            "Star",
            style = MaterialTheme.typography.displayMedium,
            color = StarColors.textPrimary,
            fontWeight = FontWeight.Light,
        )
        Text(
            "Nighttime Timelapse Airplane Remover",
            style = MaterialTheme.typography.bodyLarge,
            color = StarColors.textSecondary,
        )

        Spacer(Modifier.height(32.dp))

        // Engine status badge
        EngineStatusBadge(status = engineStatus, onRestart = onRestartEngine)

        Spacer(Modifier.height(40.dp))

        // Drop zone + open buttons
        DropZoneCard(
            onOpenSequence = onOpenSequence,
            onOpenConfig = onOpenConfig,
            onOpenVideo = onOpenVideo,
        )

        Spacer(Modifier.height(32.dp))

        // Recent files
        val recentFiles = prefs.recentFiles
        if (recentFiles.isNotEmpty()) {
            RecentFilesList(
                recentFiles = recentFiles,
                onOpen = { path ->
                    val file = File(path)
                    when {
                        file.name == "config.json" -> onOpenConfig(path)
                        file.isDirectory -> onOpenSequence(path)
                        else -> onOpenSequence(file.parent ?: path)
                    }
                },
            )
        }
    }
}

@Composable
private fun EngineStatusBadge(status: EngineStatus, onRestart: () -> Unit) {
    val (text, color) = when (status) {
        is EngineStatus.Disconnected -> "Engine: not started" to Color.Gray
        is EngineStatus.Connecting   -> "Engine: connecting…" to Color.Yellow
        is EngineStatus.Connected    -> "Engine: ready (${status.daemonVersion})" to Color.Green
        is EngineStatus.Failed       -> "Engine: stopped — ${status.message}" to Color.Red
    }

    Row(verticalAlignment = Alignment.CenterVertically) {
        Surface(
            shape = MaterialTheme.shapes.small,
            color = color.copy(alpha = 0.15f),
            modifier = Modifier.padding(4.dp),
        ) {
            Text(text, Modifier.padding(horizontal = 12.dp, vertical = 4.dp), color = color, fontSize = 12.sp)
        }
        if (status is EngineStatus.Failed) {
            Spacer(Modifier.width(8.dp))
            TextButton(onClick = onRestart) { Text("Restart") }
        }
    }
}

@Composable
private fun DropZoneCard(
    onOpenSequence: (String) -> Unit,
    onOpenConfig: (String) -> Unit,
    onOpenVideo: (String) -> Unit,
) {
    Card(
        modifier = Modifier.size(400.dp, 160.dp),
        colors = CardDefaults.cardColors(containerColor = StarColors.buttonBg),
    ) {
        Column(
            Modifier.fillMaxSize().padding(16.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center,
        ) {
            Text(
                "Drop a sequence folder, config.json, or video here",
                color = StarColors.textSecondary,
                fontSize = 14.sp,
                textAlign = androidx.compose.ui.text.style.TextAlign.Center,
            )
            Spacer(Modifier.height(16.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedButton(onClick = {
                    pickDirectory()?.let { onOpenSequence(it) }
                }) { Text("Open Sequence") }
                OutlinedButton(onClick = {
                    pickFile("*.json")?.let { onOpenConfig(it) }
                }) { Text("Open Config") }
                OutlinedButton(onClick = {
                    pickFile("*.mp4;*.mov;*.mkv")?.let { onOpenVideo(it) }
                }) { Text("Open Video") }
            }
        }
    }
}

@Composable
private fun RecentFilesList(
    recentFiles: List<Pair<String, Long>>,
    onOpen: (String) -> Unit,
) {
    Column(Modifier.widthIn(max = 600.dp)) {
        Text(
            "Recent",
            style = MaterialTheme.typography.titleSmall,
            color = StarColors.textSecondary,
            modifier = Modifier.padding(bottom = 8.dp),
        )
        recentFiles.take(10).forEach { (path, _) ->
            Row(
                Modifier
                    .fillMaxWidth()
                    .clickable { onOpen(path) }
                    .padding(vertical = 6.dp, horizontal = 4.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    File(path).name,
                    color = StarColors.textPrimary,
                    fontSize = 13.sp,
                    modifier = Modifier.weight(1f),
                )
                Text(
                    File(path).parent ?: "",
                    color = StarColors.textSecondary,
                    fontSize = 11.sp,
                )
            }
            Divider(color = StarColors.panelBorder, thickness = 0.5.dp)
        }
    }
}

private fun pickDirectory(): String? {
    val dialog = FileDialog(null as java.awt.Frame?, "Open Sequence Folder", FileDialog.LOAD)
    dialog.isMultipleMode = false
    dialog.isVisible = true
    val file = dialog.file ?: return null
    val dir = dialog.directory ?: return null
    return File(dir, file).let { if (it.isDirectory) it.absolutePath else it.parent }
}

private fun pickFile(filter: String): String? {
    val dialog = FileDialog(null as java.awt.Frame?, "Open File", FileDialog.LOAD)
    dialog.isVisible = true
    val file = dialog.file ?: return null
    val dir = dialog.directory ?: return null
    return "$dir$file"
}
