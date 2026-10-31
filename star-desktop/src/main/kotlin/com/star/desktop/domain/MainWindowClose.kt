package com.star.desktop.domain

/**
 * What the main window's close button does (parity plan D10, M10). On a Mac the macOS gui unloads the sequence and closes the window, and the app
 * keeps running (the Dock icon brings a window back, on the start screen); the desktop client does the same there. Windows and Linux have no such
 * convention, and the window's close button quits, as it did (the plan's documented platform exception).
 */
enum class MainWindowClose {
    /** The app quits (after the question about work in progress). */
    QUIT,

    /** The sequence is unloaded (after the question) and the window is hidden; the app keeps running, and shows the window again when it is raised. */
    UNLOAD_AND_HIDE;

    companion object {
        fun forSystem(osName: String): MainWindowClose = if (osName.startsWith("Mac", ignoreCase = true)) UNLOAD_AND_HIDE else QUIT

        val current: MainWindowClose by lazy { forSystem(System.getProperty("os.name") ?: "") }
    }
}
