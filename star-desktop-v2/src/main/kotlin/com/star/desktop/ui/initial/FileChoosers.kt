package com.star.desktop.ui.initial

import java.awt.FileDialog
import java.awt.Frame
import javax.swing.JFileChooser

/** How a chosen path should be opened. */
enum class OpenKind { SEQUENCE, VIDEO, CONFIG }

private val VIDEO_EXTS = setOf("mov", "mp4", "m4v", "avi", "mkv", "mpg", "mpeg")

/** Infer how to open [path]: a `config.json` resumes; a video extension imports; else a sequence dir. */
fun inferOpenKind(path: String): OpenKind = when {
    path.endsWith("config.json", ignoreCase = true) -> OpenKind.CONFIG
    path.substringAfterLast('.', "").lowercase() in VIDEO_EXTS -> OpenKind.VIDEO
    else -> OpenKind.SEQUENCE
}

/** Native directory chooser (image sequence). Blocks on the EDT. */
fun chooseDirectory(): String? {
    val chooser = JFileChooser().apply {
        fileSelectionMode = JFileChooser.DIRECTORIES_ONLY
        dialogTitle = "Open Image Sequence"
    }
    return if (chooser.showOpenDialog(null) == JFileChooser.APPROVE_OPTION) chooser.selectedFile?.absolutePath else null
}

/** Native file chooser. Blocks on the EDT. */
fun chooseFile(title: String): String? {
    val dialog = FileDialog(null as Frame?, title, FileDialog.LOAD)
    dialog.isVisible = true
    val dir = dialog.directory ?: return null
    val file = dialog.file ?: return null
    return dir + file
}
