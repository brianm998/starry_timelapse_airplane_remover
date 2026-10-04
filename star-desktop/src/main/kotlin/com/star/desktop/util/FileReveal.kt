package com.star.desktop.util

import java.awt.Desktop
import java.io.File
import java.io.IOException
import java.util.concurrent.TimeUnit

/**
 * Shows a file in the operating system's file manager: its folder, with the file selected where
 * the platform can do that (Finder on macOS, Explorer on Windows) and the folder alone where it
 * cannot (most Linux desktops). This is what the Mac app's "Reveal In Finder" does, for the clients
 * that are not on a Mac.
 *
 * The JDK knows how on the platforms that have it, as `Desktop.browseFileDirectory`. Where it has no
 * such action (every Linux desktop peer lacks it) the platform's own command is run instead.
 *
 * [reveal] answers whether a file manager was asked to show the file, not whether it has: it does not
 * wait for one to open. It can block for a few seconds on the command, so call it off the UI thread.
 */
object FileReveal {

    enum class Platform { MAC, WINDOWS, OTHER }

    /** `os.name` is `Mac OS X` on a Mac (and `Darwin` in some reports, which contains "win"). */
    internal fun platform(osName: String): Platform {
        val name = osName.lowercase()
        return when {
            name.contains("mac") || name.contains("darwin") -> Platform.MAC
            name.startsWith("windows") -> Platform.WINDOWS
            else -> Platform.OTHER
        }
    }

    /** A command to run, and whether its exit status says if it worked. */
    internal data class Command(val args: List<String>, val exitStatusMatters: Boolean)

    /**
     * The command that reveals [path] on [osName], for when the JDK cannot. [path] is the platform's
     * own spelling of it (`File.absolutePath`), which Explorer needs: it will not select a file given
     * with forward slashes.
     */
    internal fun commandFor(osName: String, path: String): Command? = when (platform(osName)) {
        Platform.MAC -> Command(listOf("open", "-R", path), exitStatusMatters = true)
        // Explorer exits 1 when it has done what it was asked, so its status says nothing. It also
        // wants `/select,` and the path as two arguments: as one, Java quotes the whole of it and
        // Explorer, finding no path in the quotes, opens the wrong folder if the path has a space.
        Platform.WINDOWS -> Command(listOf("explorer.exe", "/select,", path), exitStatusMatters = false)
        // xdg-open can open a folder, but has no way to select a file in it.
        Platform.OTHER -> File(path).parent?.let { Command(listOf("xdg-open", it), exitStatusMatters = true) }
    }

    /** Shows [file] in the file manager; false if it is not there or nothing could be started. */
    fun reveal(file: File): Boolean =
        reveal(file.absolutePath, System.getProperty("os.name").orEmpty(), ::browseWithJdk, ::execute)

    /** [reveal] with the two things it asks of the machine given, so that a test can stand in for them. */
    internal fun reveal(path: String, osName: String, browse: (String) -> Boolean, execute: (Command) -> Boolean): Boolean {
        if (!File(path).exists()) return false
        if (browse(path)) return true
        val command = commandFor(osName, path) ?: return false
        return execute(command)
    }

    private fun browseWithJdk(path: String): Boolean {
        if (!Desktop.isDesktopSupported()) return false   // false when headless, too
        val desktop = Desktop.getDesktop()
        if (!desktop.isSupported(Desktop.Action.BROWSE_FILE_DIR)) return false
        return try {
            desktop.browseFileDirectory(File(path))
            true
        } catch (e: Exception) {
            Log.w("FileReveal") { "Desktop.browseFileDirectory failed: ${e.message}" }
            false
        }
    }

    private fun execute(command: Command): Boolean = try {
        val process = ProcessBuilder(command.args)
            .redirectOutput(ProcessBuilder.Redirect.DISCARD)
            .redirectError(ProcessBuilder.Redirect.DISCARD)
            .start()
        when {
            !command.exitStatusMatters -> true
            // some desktops keep xdg-open running for as long as the file manager it started is open
            !process.waitFor(5, TimeUnit.SECONDS) -> true
            else -> (process.exitValue() == 0).also {
                if (!it) Log.w("FileReveal") { "${command.args.first()} exited with ${process.exitValue()}" }
            }
        }
    } catch (e: IOException) {
        Log.w("FileReveal") { "could not start ${command.args.first()}: ${e.message}" }
        false
    }
}
