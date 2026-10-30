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
import com.star.desktop.domain.usesOutliers
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
    // Under the processing screen no key should act on what is behind it; while painting a horizon, the keys that change what is going on don't either.
    val modalUp = svm?.showProcessingModal?.collectAsState()?.value == true
    val keys = hasSession && !modalUp
    val paintingHorizon = svm?.horizonPaintMode?.collectAsState()?.value == true

    MenuBar {
        Menu(localized("ui.file"), mnemonic = 'F') {
            // Each is behind the work-in-progress question (`requestOpen`): opening replaces the sequence that is open.
            Item(localized("ui.open_image_sequence"), shortcut = primaryShortcut(Key.O)) {
                app.requestOpen { chooseDirectory()?.let { app.requestSequence(it) } }
            }
            Item(localized("ui.open_video")) {
                app.requestOpen { chooseFile(localized("ui.open_video_title"))?.let { app.openVideo(it) } }
            }
            Item(localized("ui.resume_from_config_json")) {
                app.requestOpen { chooseFile(localized("ui.resume_from_config_title"), setOf("json"))?.let { app.openConfig(it) } }
            }
            Separator()
            // Preferences are in the app menu on a Mac (see Main.kt, which hooks the system's), and have no app menu to be in anywhere else.
            if (!IS_MAC) Item(localized("menu.preferences"), shortcut = primaryShortcut(Key.Comma)) { app.openPreferences() }
            Item(localized("ui.close"), enabled = hasSession, shortcut = primaryShortcut(Key.W)) {
                app.requestCloseSession()
            }
        }

        Menu(localized("ui.view"), mnemonic = 'V') {
            // Disabled while the horizon painter is open: Compose delivers a menu accelerator before it delivers the key
            // to the view, so E would switch mode instead of selecting ground, and S or G during the startup painting
            // would leave the painter without its startup flow (macOS disables S there).
            val painting = svm?.horizonPaintMode?.collectAsState()?.value == true
            Item(localized("ui.edit_mode"), enabled = keys && !painting, shortcut = KeyShortcut(Key.E)) { svm?.setMode(InteractionMode.EDIT) }
            Item(localized("ui.scrub_mode"), enabled = keys && !painting, shortcut = KeyShortcut(Key.S)) { svm?.setMode(InteractionMode.SCRUB) }
            Item(localized("ui.grid_mode"), enabled = keys && !painting, shortcut = KeyShortcut(Key.G)) { svm?.setMode(InteractionMode.GRID) }
            Separator()
            Item(localized("ui.toggle_filmstrip"), enabled = hasSession) { svm?.toggleFilmstrip() }
            // Tab also does this, but a focused control can take Tab for focus traversal before it gets here, so the menu is the way that always works.
            Item(localized("ui.toggle_side_panels"), enabled = hasSession) { svm?.toggleSidePanels() }
            Item(localized("ui.play_pause"), enabled = keys && !painting, shortcut = KeyShortcut(Key.Spacebar)) { svm?.playForward() }
        }

        Menu(localized("ui.process"), mnemonic = 'P') {
            // Through the app, not straight to the session: it is what asks about rendering a video before and after.
            Item(localized("ui.process_all_frames"), enabled = hasSession) { app.requestProcessAll() }
            Item(localized("ui.process_frames_from_here_to_the_end"), enabled = hasSession) { svm?.processRemaining() }
            Item(localized("ui.process_current_frame"), enabled = hasSession) { svm?.processCurrent() }
            Item(localized("ui.re_process_this_frame_from_the_start"), enabled = hasSession) { svm?.reprocessCurrent() }
            Item(localized("ui.find_outliers_for_this_frame"), enabled = hasSession) { svm?.findOutliersCurrent() }
            Separator()
            // The classifier over this frame's outliers, and writing the decisions into its picture (also on the d and r keys).
            val currentFrame = svm?.currentIndex?.collectAsState()?.value ?: 0
            val currentMethod = svm?.frameVMFor(currentFrame)?.info?.collectAsState()?.value?.cleanMethod
            val usesOutliers = currentMethod?.usesOutliers ?: true
            Item(localized("ui.decision_tree_all"), enabled = hasSession && usesOutliers) { svm?.applyDecisionTreeToCurrentFrame() }
            Item(localized("ui.dt_auto_only"), enabled = hasSession && usesOutliers) { svm?.applyDecisionTreeToCurrentFrame(autoOnly = true) }
            // Every frame at once: this was a button in the right panel, which the gui's panel never had (owner decision D8), so it is a command.
            Item(localized("ui.decision_tree_all_frames"), enabled = hasSession) { svm?.applyDecisionTreeAll() }
            Item(localized("ui.render_this_frame"), enabled = hasSession) { svm?.renderCurrentFrame() }
            Item(localized("ui.render_all_frames"), enabled = hasSession) { svm?.renderAllFrames() }
            Separator()
            Item(localized("ui.cancel_processing"), enabled = hasSession) { svm?.cancelProcessing() }
            Separator()
            Item(localized("ui.processing_settings_2"), enabled = hasSession, shortcut = primaryShortcut(Key.Comma, shift = true)) { app.openSettings() }
        }

        Menu(localized("ui.export"), mnemonic = 'E') {
            Item(localized("ui.render_video_2"), enabled = hasSession) { app.openRenderVideo() }
        }

        Menu(localized("ui.window"), mnemonic = 'W') {
            Item(localized("ui.blob_processing_window"), shortcut = windowShortcut(Key.P, IS_MAC)) { app.toggleBlobWindow() }
            Item(localized("ui.outlier_information_window"), enabled = hasSession, shortcut = windowShortcut(Key.O, IS_MAC)) { app.toggleOutlierWindow() }
            Item(localized("ui.alignment_information_window"), enabled = hasSession, shortcut = windowShortcut(Key.A, IS_MAC)) { app.toggleAlignmentWindow() }
            Item(localized("ui.debug_window"), shortcut = windowShortcut(Key.D, IS_MAC)) { app.toggleDebugWindow() }
            Separator()
            // The same item closes the painter while it is open, and says so (macOS).
            Item(localized(if (paintingHorizon) "ui.close_horizon_painter" else "ui.paint_horizon_reference"), enabled = keys, shortcut = KeyShortcut(Key.H)) {
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
            Item(localized("ui.keep_all"), enabled = keys && !paintingHorizon, shortcut = KeyShortcut(Key.K)) {
                svm?.let { it.frameVMFor(it.currentIndex.value).keepAll(it.showTrash.value) }
            }
            Item(localized("ui.remove_all"), enabled = keys && !paintingHorizon, shortcut = KeyShortcut(Key.A)) {
                svm?.let { it.frameVMFor(it.currentIndex.value).removeAll(it.showTrash.value) }
            }
            Item(localized("ui.clear_undecided"), enabled = keys && !paintingHorizon, shortcut = KeyShortcut(Key.U)) {
                svm?.let { it.frameVMFor(it.currentIndex.value).clearUndecided(it.showTrash.value) }
            }
            Separator()
            ToolType.selectable.forEachIndexed { i, t ->
                Item(localized("ui.tool_n", t.displayName, i + 1), enabled = hasSession) { svm?.setTool(t) }
            }
        }
    }
}

/** True on macOS — used to map the primary modifier to Cmd there and Ctrl elsewhere. */
internal val IS_MAC: Boolean = System.getProperty("os.name").orEmpty().lowercase().contains("mac")

/**
 * The platform's primary-accelerator modifier: Cmd on macOS, Ctrl on Windows/Linux. Compose Desktop's
 * `meta` does **not** fall back to Ctrl off-Mac, so ⌘O/⌘W/⌘, (and the Cmd+Opt window toggles) would
 * be dead on Windows/Linux without this branch.
 */
private fun primaryShortcut(key: Key, alt: Boolean = false, shift: Boolean = false): KeyShortcut =
    KeyShortcut(key, meta = IS_MAC, ctrl = !IS_MAC, alt = alt, shift = shift)

/**
 * The shortcut of a window item (the outlier table, the alignment window). On macOS it is Option plus the letter, as in the Mac app; elsewhere
 * Ctrl+Alt+letter, since a plain Alt+letter opens a menu by its mnemonic on Windows and Linux. The menu shows whichever it is.
 */
internal fun windowShortcut(key: Key, isMac: Boolean): KeyShortcut =
    if (isMac) KeyShortcut(key, alt = true) else KeyShortcut(key, ctrl = true, alt = true)
