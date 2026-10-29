package com.star.desktop.ui.initial

import com.star.desktop.i18n.localized
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

/**
 * Infer how to open [path]: a `.json` is a session's config and resumes it; a video extension imports;
 * else a sequence dir. (Older recent entries are the folder or video itself, not its config.)
 */
fun inferOpenKind(path: String): OpenKind = when {
    path.endsWith(".json", ignoreCase = true) -> OpenKind.CONFIG
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

/** Native directory chooser (image sequence by default, or a folder for [title]). Opens at [startAt] when that is a folder. Blocks on the EDT. */
fun chooseDirectory(title: String = localized("ui.open_image_sequence").trimEnd('…', '.'), startAt: String? = null): String? {
    val chooser = JFileChooser().apply {
        fileSelectionMode = JFileChooser.DIRECTORIES_ONLY
        dialogTitle = title
        startAt?.let { File(it).takeIf { f -> f.isDirectory }?.let { f -> currentDirectory = f } }
    }
    return if (chooser.showOpenDialog(null) == JFileChooser.APPROVE_OPTION) chooser.selectedFile?.absolutePath else null
}

/** Whether [name] ends in one of [extensions] (given without the dot), whatever its case. */
internal fun hasExtension(name: String, extensions: Set<String>): Boolean =
    extensions.any { name.endsWith(".$it", ignoreCase = true) }

/**
 * Native file chooser. Blocks on the EDT. With [extensions] only files of those kinds are offered (macOS limits Resume from config.json to
 * `.json`); on Windows the box is also pre-filled with the pattern, which is how a native dialog there narrows what it lists.
 */
fun chooseFile(title: String, extensions: Set<String>? = null): String? {
    val dialog = FileDialog(null as Frame?, title, FileDialog.LOAD)
    if (extensions != null) {
        dialog.setFilenameFilter { dir, name -> File(dir, name).isDirectory || hasExtension(name, extensions) }
        if (System.getProperty("os.name").orEmpty().lowercase().contains("win")) dialog.file = extensions.joinToString(";") { "*.$it" }
    }
    dialog.isVisible = true
    val dir = dialog.directory ?: return null
    val file = dialog.file ?: return null
    return dir + file
}
