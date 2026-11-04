package com.star.desktop.ui.initial

import java.io.File
import java.io.IOException
import java.util.Base64
import java.util.concurrent.TimeUnit

/** Which folder dialog a platform gets. */
internal enum class FolderPicker { MAC_PANEL, WINDOWS_EXPLORER, LINUX_NATIVE, SWING }

/** The folder dialog for the JVM's `os.name`: the platform's own where there is one, Swing's `JFileChooser` otherwise. */
internal fun folderPickerFor(osName: String): FolderPicker {
    val os = osName.lowercase()
    return when {
        os.contains("mac") || os.contains("darwin") -> FolderPicker.MAC_PANEL
        os.contains("win") -> FolderPicker.WINDOWS_EXPLORER
        os.contains("linux") || os.contains("nux") || os.contains("nix") -> FolderPicker.LINUX_NATIVE
        else -> FolderPicker.SWING
    }
}

/** What a native folder dialog that runs as a helper process came back with. */
internal sealed interface FolderResult {
    data class Chosen(val folder: File) : FolderResult
    data object Cancelled : FolderResult
    /** The helper is missing, would not start or failed: the caller falls back to the next chooser. */
    data object Unavailable : FolderResult
}

/** The dialogs [chooseDirectory] can show, so the platform choice is testable without showing any. */
internal class FolderDialogs(
    val mac: (String, File?) -> File?,
    val windows: (String, File?) -> FolderResult,
    val linux: (String, File?) -> FolderResult,
    val swing: (String, File?) -> File?,
)

/** `zenity` (GTK, which reaches the desktop portal under Wayland) as a folder chooser. */
internal fun zenityCommand(title: String, start: File?): List<String> =
    buildList {
        add("zenity"); add("--file-selection"); add("--directory"); add("--title=$title")
        // A trailing slash makes GTK open inside the folder rather than select it in its parent.
        start?.let { add("--filename=" + it.absolutePath.trimEnd('/') + "/") }
    }

/** `kdialog`, for KDE desktops without zenity. */
internal fun kdialogCommand(title: String, start: File?): List<String> =
    buildList {
        add("kdialog"); add("--title"); add(title); add("--getexistingdirectory")
        add(start?.absolutePath ?: System.getProperty("user.home").orEmpty().ifEmpty { "/" })
    }

/** The PowerShell invocation of `folder-picker.ps1`; the script travels as `-EncodedCommand` (base64 of UTF-16LE). */
internal fun powershellCommand(script: String): List<String> =
    listOf(
        "powershell.exe", "-NoProfile", "-NonInteractive", "-STA",
        "-EncodedCommand", Base64.getEncoder().encodeToString(script.toByteArray(Charsets.UTF_16LE)),
    )

/**
 * Maps a helper's exit status and stdout to a result. Exit 0 with a path is a choice; exit 1 is the user cancelling (zenity, kdialog and
 * the PowerShell script all use it); anything else means the helper itself did not work.
 */
internal fun folderResultOf(exitCode: Int, stdout: String): FolderResult {
    val path = stdout.lineSequence().map { it.trim() }.firstOrNull { it.isNotEmpty() }
    return when (exitCode) {
        0 -> if (path == null) FolderResult.Cancelled else FolderResult.Chosen(File(path))
        1 -> FolderResult.Cancelled
        else -> FolderResult.Unavailable
    }
}

/** Runs [command] and waits for the user to finish with the dialog it shows. A helper that cannot be started is [FolderResult.Unavailable]. */
private fun runHelper(command: List<String>, env: Map<String, String> = emptyMap()): FolderResult {
    val process = try {
        ProcessBuilder(command)
            .redirectError(ProcessBuilder.Redirect.DISCARD)
            .apply { environment().putAll(env) }
            .start()
    } catch (_: IOException) {
        return FolderResult.Unavailable
    }
    return try {
        process.outputStream.close()
        val out = process.inputStream.readBytes().toString(Charsets.UTF_8)
        folderResultOf(process.waitFor(), out)
    } catch (_: IOException) {
        FolderResult.Unavailable
    } finally {
        process.destroy()
    }
}

/** Explorer's own folder picker, through PowerShell (which ships with Windows) hosting `IFileOpenDialog`. */
internal fun windowsFolderDialog(title: String, start: File?): FolderResult {
    val script = object {}.javaClass.getResourceAsStream("/folder-picker.ps1")?.use { it.readBytes().toString(Charsets.UTF_8) }
        ?: return FolderResult.Unavailable
    val env = mapOf("STAR_TITLE" to title, "STAR_START" to (start?.absolutePath ?: ""))
    return runHelper(powershellCommand(script), env)
}

/** The desktop's folder chooser through zenity, else kdialog; [FolderResult.Unavailable] when neither is installed. */
internal fun linuxFolderDialog(title: String, start: File?): FolderResult {
    val viaZenity = runHelper(zenityCommand(title, start))
    if (viaZenity != FolderResult.Unavailable) return viaZenity
    return runHelper(kdialogCommand(title, start))
}
