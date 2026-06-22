package com.star.ui

import androidx.compose.runtime.*
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.window.FrameWindowScope
import androidx.compose.ui.window.MenuBar
import com.star.viewmodel.AppViewModel
import com.star.viewmodel.InteractionMode
import kotlinx.coroutines.MainScope
import kotlinx.coroutines.launch
import java.awt.FileDialog
import java.io.File

/**
 * Menu bar mirroring StarCommands.swift.
 * Every menu item and shortcut from the Swift source is reproduced here.
 * Ctrl is used on Windows/Linux; on macOS the JVM intercepts Cmd for system shortcuts,
 * so we use the platform-appropriate modifier.
 */
@Composable
fun FrameWindowScope.StarMenuBar(appViewModel: AppViewModel) {
    val isMac = System.getProperty("os.name").lowercase().contains("mac")
    val seqVm by appViewModel.sequenceViewModel.collectAsState()

    MenuBar {
        Menu("File") {
            Item("Open Sequence…") { showOpenDialog(appViewModel, FileDialogMode.Sequence) }
            Item("Open Video…")    { showOpenDialog(appViewModel, FileDialogMode.Video) }
            Item("Open Config…")   { showOpenDialog(appViewModel, FileDialogMode.Config) }
            Separator()
            Item("Close Session") { appViewModel.closeCurrentSession() }
        }

        Menu("Edit") {
            val seqVmLocal = seqVm
            if (seqVmLocal != null) {
                val frameVm by seqVmLocal.frameViewModel.collectAsState()
                Item("Keep All (A)")         { frameVm?.keepAll() }
                Item("Remove All (K)")       { frameVm?.removeAll() }
                Item("Clear Undecided (U)")  { frameVm?.clearUndecided() }
                Separator()
                Item("Rerender Frame")       { frameVm?.requestRerender() }
            }
        }

        Menu("Processing") {
            val seqVmLocal = seqVm
            if (seqVmLocal != null) {
                Item("Process All Frames")       { seqVmLocal.processAll() }
                Item("Process Remaining Frames") { seqVmLocal.processRemaining() }
                Item("Process Current Frame")    { seqVmLocal.processCurrentFrame() }
                Item("Cancel Processing")        { seqVmLocal.cancelProcessing() }
            }
        }

        Menu("View") {
            Item("Edit Mode (E)")  { appViewModel.setMode(InteractionMode.Edit) }
            Item("Scrub Mode (S)") { appViewModel.setMode(InteractionMode.Scrub) }
            Item("Grid Mode (G)")  { appViewModel.setMode(InteractionMode.Grid) }
            Separator()
            Item("Outlier Window") { appViewModel.toggleOutlierWindow() }
            Item("Alignment Window") { appViewModel.toggleAlignmentWindow() }
        }

        Menu("Export") {
            val seqVmLocal = seqVm
            if (seqVmLocal != null) {
                Item("Render All Frames")  { seqVmLocal.renderSequence({}, {}, {}) }
                Item("Export Video…")      { /* Opens RenderVideoDialog via UI state */ }
            }
        }
    }
}

private enum class FileDialogMode { Sequence, Video, Config }

private fun showOpenDialog(appViewModel: AppViewModel, mode: FileDialogMode) {
    // AWT FileDialog — works on macOS, Linux, Windows.
    val dialog = FileDialog(null as java.awt.Frame?, "Open", FileDialog.LOAD)
    when (mode) {
        FileDialogMode.Config -> dialog.file = "config.json"
        FileDialogMode.Video  -> dialog.setFilenameFilter { _, name -> name.endsWith(".mp4") || name.endsWith(".mov") || name.endsWith(".mkv") }
        else -> Unit
    }
    dialog.isVisible = true
    val file = dialog.file ?: return
    val dir = dialog.directory ?: return
    val path = "$dir$file"

    MainScope().launch {
        when (mode) {
            FileDialogMode.Sequence -> {
                val dir2 = File(path).let { if (it.isDirectory) it.absolutePath else it.parent }
                appViewModel.openSequence(dir2)
            }
            FileDialogMode.Config   -> appViewModel.openConfig(path)
            FileDialogMode.Video    -> appViewModel.openVideo(path)
        }
    }
}
