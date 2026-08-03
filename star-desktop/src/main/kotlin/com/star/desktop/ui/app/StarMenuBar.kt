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
import com.star.desktop.i18n.Strings
import com.star.desktop.i18n.localized

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
        Menu(localized("ui.file"), mnemonic = 'F') {
            Item(localized("ui.open_image_sequence"), shortcut = primaryShortcut(Key.O)) {
                chooseDirectory()?.let { app.openSequence(it) }
            }
            Item(localized("ui.open_video")) {
                chooseFile(localized("ui.open_video_title"))?.let { app.openVideo(it) }
            }
            Item(localized("ui.resume_from_config_json")) {
                chooseFile(localized("ui.resume_from_config_title"))?.let { app.openConfig(it) }
            }
            Separator()
            Item(localized("ui.close_session"), enabled = hasSession, shortcut = primaryShortcut(Key.W)) {
                app.closeSession()
            }
        }

        Menu(localized("ui.view"), mnemonic = 'V') {
            Item(localized("ui.edit_mode"), enabled = hasSession, shortcut = KeyShortcut(Key.E)) { svm?.setMode(InteractionMode.EDIT) }
            Item(localized("ui.scrub_mode"), enabled = hasSession, shortcut = KeyShortcut(Key.S)) { svm?.setMode(InteractionMode.SCRUB) }
            Item(localized("ui.grid_mode"), enabled = hasSession, shortcut = KeyShortcut(Key.G)) { svm?.setMode(InteractionMode.GRID) }
            Separator()
            Item(localized("ui.toggle_filmstrip"), enabled = hasSession) { svm?.toggleFilmstrip() }
            Item(localized("ui.play_pause"), enabled = hasSession, shortcut = KeyShortcut(Key.Spacebar)) { svm?.togglePlayback() }
        }

        Menu(localized("ui.process"), mnemonic = 'P') {
            Item(localized("ui.process_all_frames_2"), enabled = hasSession) { svm?.processAll() }
            Item(localized("ui.process_remaining"), enabled = hasSession) { svm?.processRemaining() }
            Item(localized("ui.process_current_frame"), enabled = hasSession) { svm?.processCurrent() }
            Separator()
            Item(localized("ui.cancel_processing"), enabled = hasSession) { svm?.cancelProcessing() }
            Separator()
            Item(localized("ui.processing_settings_2"), enabled = hasSession, shortcut = primaryShortcut(Key.Comma)) { app.openSettings() }
        }

        Menu(localized("ui.export"), mnemonic = 'E') {
            Item(localized("ui.render_video_2"), enabled = hasSession) { app.openRenderVideo() }
        }

        Menu(localized("ui.window"), mnemonic = 'W') {
            Item(localized("ui.outlier_table"), enabled = hasSession, shortcut = primaryShortcut(Key.X, alt = true)) { app.toggleOutlierWindow() }
            Item(localized("ui.alignment_2"), enabled = hasSession, shortcut = primaryShortcut(Key.A, alt = true)) { app.toggleAlignmentWindow() }
            Separator()
            Item(localized("ui.paint_reference_horizon"), enabled = hasSession, shortcut = KeyShortcut(Key.H)) {
                svm?.let { if (it.mode.value != InteractionMode.EDIT) it.setMode(InteractionMode.EDIT); it.toggleHorizonPaint() }
            }
        }

        // Window ▸ Language ▸ …. The macOS app puts this in its app menu, which is where a
        // Mac user looks; Compose Desktop has no app menu on Windows or Linux, and this menu
        // bar is shared across all three, so it goes in the last menu instead of somewhere
        // that only exists on one platform.
        //
        // Every language is listed in its own script on purpose: someone who has landed in a
        // language they cannot read finds their way back by recognising their own name for it.
        Menu(localized("language.menu"), mnemonic = 'L') {
            RadioButtonItem(
                localized("language.follow_system"),
                selected = Strings.isFollowingSystem,
            ) { app.setLanguage(null) }

            Separator()

            for (language in app.availableLanguages) {
                RadioButtonItem(
                    language.nativeName,
                    selected = !Strings.isFollowingSystem && Strings.currentCode == language.code,
                ) { app.setLanguage(language.code) }
            }
        }

        Menu(localized("ui.outliers"), mnemonic = 'O') {
            // Accelerators per the authoritative Swift source (StarCommands.swift): 'a' removes all,
            // 'k' keeps all, 'u' clears undecided. (KOTLIN_CLIENT_SPEC §5.8's prose had a/k swapped.)
            Item(localized("ui.keep_all"), enabled = hasSession, shortcut = KeyShortcut(Key.K)) {
                svm?.let { it.frameVMFor(it.currentIndex.value).keepAll() }
            }
            Item(localized("ui.remove_all"), enabled = hasSession, shortcut = KeyShortcut(Key.A)) {
                svm?.let { it.frameVMFor(it.currentIndex.value).removeAll() }
            }
            Item(localized("ui.clear_undecided"), enabled = hasSession, shortcut = KeyShortcut(Key.U)) {
                svm?.let { it.frameVMFor(it.currentIndex.value).clearUndecided() }
            }
            Separator()
            ToolType.selectable.forEachIndexed { i, t ->
                Item(localized("ui.tool_n", t.displayName, i + 1), enabled = hasSession) { svm?.setTool(t) }
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
