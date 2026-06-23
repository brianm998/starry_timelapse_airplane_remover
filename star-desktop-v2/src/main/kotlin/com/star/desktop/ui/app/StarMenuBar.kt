package com.star.desktop.ui.app

import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyShortcut
import androidx.compose.ui.window.FrameWindowScope
import androidx.compose.ui.window.MenuBar
import com.star.desktop.domain.InteractionMode
import com.star.desktop.domain.ToolType
import com.star.desktop.ui.initial.OpenKind
import com.star.desktop.ui.initial.chooseDirectory
import com.star.desktop.ui.initial.chooseFile

/**
 * The application menu bar (macOS `StarCommands`) — mounted on the window (the v1 client defined a
 * menu but never mounted it). Items enable/disable on session presence and route to the app /
 * sequence view models. Mode/tool/outlier accelerators mirror the macOS shortcuts.
 */
@Composable
fun FrameWindowScope.StarMenuBar(app: AppViewModel) {
    val screen by app.screen.collectAsState()
    val svm = (screen as? AppScreen.Sequence)?.vm
    val hasSession = svm != null

    MenuBar {
        Menu("File", mnemonic = 'F') {
            Item("Open Image Sequence…", shortcut = primaryShortcut(Key.O)) {
                chooseDirectory()?.let { app.openSequence(it) }
            }
            Item("Open Video…") {
                chooseFile("Open Video")?.let { app.openVideo(it) }
            }
            Item("Resume from config.json…") {
                chooseFile("Resume from config.json")?.let { app.openConfig(it) }
            }
            Separator()
            Item("Close Session", enabled = hasSession, shortcut = primaryShortcut(Key.W)) {
                app.closeSession()
            }
        }

        Menu("View", mnemonic = 'V') {
            Item("Edit Mode", enabled = hasSession, shortcut = KeyShortcut(Key.E)) { svm?.setMode(InteractionMode.EDIT) }
            Item("Scrub Mode", enabled = hasSession, shortcut = KeyShortcut(Key.S)) { svm?.setMode(InteractionMode.SCRUB) }
            Item("Grid Mode", enabled = hasSession, shortcut = KeyShortcut(Key.G)) { svm?.setMode(InteractionMode.GRID) }
            Separator()
            Item("Toggle Filmstrip", enabled = hasSession) { svm?.toggleFilmstrip() }
            Item("Play / Pause", enabled = hasSession, shortcut = KeyShortcut(Key.Spacebar)) { svm?.togglePlayback() }
        }

        Menu("Process", mnemonic = 'P') {
            Item("Process All Frames", enabled = hasSession) { svm?.processAll() }
            Item("Process Remaining", enabled = hasSession) { svm?.processRemaining() }
            Item("Process Current Frame", enabled = hasSession) { svm?.processCurrent() }
            Separator()
            Item("Cancel Processing", enabled = hasSession) { svm?.cancelProcessing() }
            Separator()
            Item("Processing Settings…", enabled = hasSession, shortcut = primaryShortcut(Key.Comma)) { app.openSettings() }
        }

        Menu("Export", mnemonic = 'E') {
            Item("Render Video…", enabled = hasSession) { app.openRenderVideo() }
        }

        Menu("Window", mnemonic = 'W') {
            Item("Outlier Table", enabled = hasSession, shortcut = primaryShortcut(Key.X, alt = true)) { app.toggleOutlierWindow() }
            Item("Alignment", enabled = hasSession, shortcut = primaryShortcut(Key.A, alt = true)) { app.toggleAlignmentWindow() }
            Separator()
            Item("Paint Reference Horizon", enabled = hasSession) {
                svm?.let { if (it.mode.value != InteractionMode.EDIT) it.setMode(InteractionMode.EDIT); it.toggleHorizonPaint() }
            }
        }

        Menu("Outliers", mnemonic = 'O') {
            // Accelerators per the authoritative Swift source (StarCommands.swift): 'a' removes all,
            // 'k' keeps all, 'u' clears undecided. (KOTLIN_CLIENT_SPEC §5.8's prose had a/k swapped.)
            Item("Keep All", enabled = hasSession, shortcut = KeyShortcut(Key.K)) {
                svm?.let { it.frameVMFor(it.currentIndex.value).keepAll() }
            }
            Item("Remove All", enabled = hasSession, shortcut = KeyShortcut(Key.A)) {
                svm?.let { it.frameVMFor(it.currentIndex.value).removeAll() }
            }
            Item("Clear Undecided", enabled = hasSession, shortcut = KeyShortcut(Key.U)) {
                svm?.let { it.frameVMFor(it.currentIndex.value).clearUndecided() }
            }
            Separator()
            ToolType.selectable.forEachIndexed { i, t ->
                Item("Tool: ${t.displayName} (${i + 1})", enabled = hasSession) { svm?.setTool(t) }
            }
        }
    }
}

/** True on macOS — used to map the primary modifier to Cmd there and Ctrl elsewhere. */
private val IS_MAC: Boolean = System.getProperty("os.name").orEmpty().lowercase().contains("mac")

/**
 * The platform's primary-accelerator modifier: Cmd on macOS, Ctrl on Windows/Linux. Compose Desktop's
 * `meta` does **not** fall back to Ctrl off-Mac, so ⌘O/⌘W/⌘, (and the Cmd+Opt window toggles) would
 * be dead on Windows/Linux without this branch.
 */
private fun primaryShortcut(key: Key, alt: Boolean = false, shift: Boolean = false): KeyShortcut =
    KeyShortcut(key, meta = IS_MAC, ctrl = !IS_MAC, alt = alt, shift = shift)
