package com.star.desktop.ui.initial

import java.awt.FileDialog
import java.awt.Frame
import java.io.File
import javax.swing.JFileChooser

/** How a chosen path should be opened. */
enum class OpenKind { SEQUENCE, VIDEO, CONFIG }

/** A resolved drop/open: which action to take and the path it applies to. */
data class OpenAction(val kind: OpenKind, val path: String)

private val VIDEO_EXTS = setOf("mov", "mp4", "m4v", "avi", "mkv", "mpg", "mpeg")
private val IMAGE_EXTS = setOf("jpg", "jpeg", "tif", "tiff", "png")

/** Infer how to open [path]: a `config.json` resumes; a video extension imports; else a sequence dir. */
fun inferOpenKind(path: String): OpenKind = when {
    path.endsWith("config.json", ignoreCase = true) -> OpenKind.CONFIG
    path.substringAfterLast('.', "").lowercase() in VIDEO_EXTS -> OpenKind.VIDEO
    else -> OpenKind.SEQUENCE
}

/**
 * Decide how to open files dropped onto the start screen, mirroring macOS `InitialView.handleDrop`:
 * several files, or a single loose image → open the containing folder as an image sequence;
 * a folder → open it as a sequence; a single `.json` → resume; anything else → import as a video.
 * Returns null when there is nothing actionable (empty drop, or a loose file with no parent folder).
 */
fun resolveDrop(files: List<File>): OpenAction? {
    val first = files.firstOrNull() ?: return null
    // Multiple files dropped: assume they're frames of one sequence, open their containing folder.
    if (files.size > 1) {
        return first.parentFile?.let { OpenAction(OpenKind.SEQUENCE, it.absolutePath) }
    }
    return when {
        first.isDirectory -> OpenAction(OpenKind.SEQUENCE, first.absolutePath)
        first.name.endsWith(".json", ignoreCase = true) -> OpenAction(OpenKind.CONFIG, first.absolutePath)
        // A single loose image is neither a video nor a sequence by itself: open its folder.
        first.extension.lowercase() in IMAGE_EXTS ->
            first.parentFile?.let { OpenAction(OpenKind.SEQUENCE, it.absolutePath) }
        else -> OpenAction(OpenKind.VIDEO, first.absolutePath)
    }
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
