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
import com.star.desktop.domain.isRendering
import com.star.desktop.domain.usesOutliers
import com.star.desktop.ui.initial.OpenKind
import com.star.desktop.ui.initial.chooseDirectory
import com.star.desktop.ui.initial.chooseFile
import com.star.desktop.i18n.Strings
import com.star.desktop.i18n.localized
import com.star.desktop.ui.sequence.SequenceViewModel

/**
 * The application menu bar (macOS `StarCommands`) — mounted on the window (the v1 client defined a
 * menu but never mounted it). The menus themselves are [starMenus], plain data; this draws them as the
 * window's AWT menu bar, which a UI test host cannot reach, so a test reads [starMenusNow] instead.
 */
@Composable
fun FrameWindowScope.StarMenuBar(app: AppViewModel) {
    val menus = starMenus(app)
    MenuBar {
        for (menu in menus) {
            Menu(menu.title, mnemonic = menu.mnemonic) {
                for (entry in menu.entries) {
                    when (entry) {
                        is MenuEntry.Command -> Item(entry.label, enabled = entry.enabled, shortcut = entry.shortcut, onClick = entry.onClick)
                        is MenuEntry.Choice -> RadioButtonItem(entry.label, selected = entry.selected, onClick = entry.onClick)
                        MenuEntry.Divider -> Separator()
                    }
                }
            }
        }
    }
}

/** One entry of a menu: a command (the AWT menu's item), a radio choice, or a separator. */
sealed interface MenuEntry {
    class Command(val label: String, val enabled: Boolean, val shortcut: KeyShortcut?, val onClick: () -> Unit) : MenuEntry
    class Choice(val label: String, val selected: Boolean, val onClick: () -> Unit) : MenuEntry
    data object Divider : MenuEntry
}

/** A menu: its title, the letter that opens it from the keyboard, and its entries in order. */
class MenuSpec(val title: String, val mnemonic: Char, val entries: List<MenuEntry>)

/** What the menu code below says its menus are, in the form the Compose `MenuBar` DSL reads: the same words (`Menu`, `Item`, `Separator`), collected instead of drawn. */
class MenuBuilder {
    val menus = mutableListOf<MenuSpec>()

    fun Menu(title: String, mnemonic: Char, build: EntriesBuilder.() -> Unit) {
        menus += MenuSpec(title, mnemonic, EntriesBuilder().apply(build).entries)
    }
}

class EntriesBuilder {
    val entries = mutableListOf<MenuEntry>()

    fun Item(label: String, enabled: Boolean = true, shortcut: KeyShortcut? = null, onClick: () -> Unit) {
        entries += MenuEntry.Command(label, enabled, shortcut, onClick)
    }

    fun RadioButtonItem(label: String, selected: Boolean, onClick: () -> Unit) {
        entries += MenuEntry.Choice(label, selected, onClick)
    }

    fun Separator() {
        entries += MenuEntry.Divider
    }
}

/**
 * What the menus' items enable on, and the gui's rules for them (`StarCommands.swift`, owner decision D9 and finding M12). Pure, so a test can
 * put the app into any state: the ones a UI feature cannot reach (a run going, the processing screen up, a video rendering) too.
 */
class MenuState(
    /** A sequence is open. */
    val hasSession: Boolean,
    /** The processing screen (or the re-open progress panel) is over the window: nothing under it answers to a key. */
    val modalUp: Boolean = false,
    /** The horizon painter is open. */
    val paintingHorizon: Boolean = false,
    /** A processing run is going. */
    val processing: Boolean = false,
    /** A video is rendering. */
    val renderingVideo: Boolean = false,
    /** The open frame's clean method reviews outliers (the desktop's own refinement: the gui leaves the decision-tree items on). */
    val usesOutliers: Boolean = true,
) {
    /** The gui's `!isProcessingModalUp`: Process Current Frame, Processing Settings, the horizon painter. */
    val notUnderModal: Boolean get() = hasSession && !modalUp

    /** The gui's `menuHotkeysEnabled`: the single-key commands (modes, tools, remove/keep/clear, render, decision tree, play). Off under a modal and while painting a horizon. */
    val hotkeys: Boolean get() = notUnderModal && !paintingHorizon

    /** The gui's `isProcessingFrames`: there is a run to cancel. */
    val canCancel: Boolean get() = hasSession && processing

    /** The gui's `!isProcessingModalUp && !isRenderingVideo`. */
    val canRenderVideo: Boolean get() = notUnderModal && !renderingVideo
}

/**
 * The menus, as they are now: items enable/disable on session presence and route to the app /
 * sequence view models. Mode/tool/outlier accelerators mirror the macOS shortcuts. Read in composition, so a
 * caller recomposes when what enables an item changes.
 */
@Composable
fun starMenus(app: AppViewModel): List<MenuSpec> {
    val screen by app.screen.collectAsState()
    val svm = (screen as? AppScreen.Sequence)?.vm
    val currentFrame = svm?.currentIndex?.collectAsState()?.value ?: 0
    val currentMethod = svm?.frameVMFor(currentFrame)?.info?.collectAsState()?.value?.cleanMethod
    val state = MenuState(
        hasSession = svm != null,
        modalUp = svm?.showProcessingModal?.collectAsState()?.value == true,
        paintingHorizon = svm?.horizonPaintMode?.collectAsState()?.value == true,
        processing = svm?.isProcessing?.collectAsState()?.value == true,
        renderingVideo = app.renderState.collectAsState().value.isRendering,
        usesOutliers = currentMethod?.usesOutliers ?: true,
    )
    return starMenus(app, svm, state)
}

/**
 * The menus as they are this moment, for a caller that is not composing (a UI test host has no menu bar to draw them on): the same menus, from the
 * same flows read once. Call it on the UI thread, where composition reads them and where the frame view models are made.
 */
fun starMenusNow(app: AppViewModel): List<MenuSpec> {
    val svm = (app.screen.value as? AppScreen.Sequence)?.vm
    val currentMethod = svm?.frameVMFor(svm.currentIndex.value)?.info?.value?.cleanMethod
    val state = MenuState(
        hasSession = svm != null,
        modalUp = svm?.showProcessingModal?.value == true,
        paintingHorizon = svm?.horizonPaintMode?.value == true,
        processing = svm?.isProcessing?.value == true,
        renderingVideo = app.isRendering,
        usesOutliers = currentMethod?.usesOutliers ?: true,
    )
    return starMenus(app, svm, state)
}

private fun starMenus(app: AppViewModel, svm: SequenceViewModel?, state: MenuState): List<MenuSpec> {
    val hasSession = state.hasSession
    val hotkeys = state.hotkeys
    val usesOutliers = state.usesOutliers

    return MenuBuilder().apply {
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

        // The gui's tree (owner decision D9): File, Actions, Tools and Window, with the items in its order. The desktop used to have View, Process,
        // Export and Outliers menus instead; `gherkin/ui/commands.json` says which menu each command is in, and a test per client holds both to it.
        Menu(localized("menu.actions"), mnemonic = 'A') {
            // Accelerators per the authoritative Swift source (StarCommands.swift): 'a' removes all,
            // 'k' keeps all, 'u' clears undecided. (KOTLIN_CLIENT_SPEC §5.8's prose had a/k swapped.)
            Item(localized("ui.remove_all"), enabled = hotkeys, shortcut = KeyShortcut(Key.A)) {
                svm?.let { it.frameVMFor(it.currentIndex.value).removeAll(it.showTrash.value) }
            }
            Item(localized("ui.keep_all"), enabled = hotkeys, shortcut = KeyShortcut(Key.K)) {
                svm?.let { it.frameVMFor(it.currentIndex.value).keepAll(it.showTrash.value) }
            }
            Item(localized("ui.clear_undecided"), enabled = hotkeys, shortcut = KeyShortcut(Key.U)) {
                svm?.let { it.frameVMFor(it.currentIndex.value).clearUndecided(it.showTrash.value) }
            }
            // Through the app, not straight to the session: it is what asks about rendering a video before and after.
            Item(localized("ui.process_all_frames"), enabled = hasSession) { app.requestProcessAll() }
            Item(localized("ui.process_frames_from_here_to_the_end"), enabled = hasSession) { svm?.processRemaining() }
            Item(localized("ui.process_current_frame"), enabled = state.notUnderModal) { svm?.processCurrent() }
            Item(localized("ui.cancel_processing"), enabled = state.canCancel) { svm?.cancelProcessing() }
            Item(localized("ui.processing_settings_2"), enabled = state.notUnderModal, shortcut = primaryShortcut(Key.Comma, shift = true)) { app.openSettings() }
            Item(localized("ui.render_video_2"), enabled = state.canRenderVideo) { app.openRenderVideo() }
            Item(localized("ui.re_process_this_frame_from_the_start"), enabled = hasSession) { svm?.reprocessCurrent() }
            Item(localized("ui.find_outliers_for_this_frame"), enabled = hasSession) { svm?.findOutliersCurrent() }
            Item(localized("ui.decision_tree_all"), enabled = hotkeys && usesOutliers) { svm?.applyDecisionTreeToCurrentFrame() }
            // Every frame at once: this was a button in the right panel, which the gui's panel never had (owner decision D8), so it is a command.
            Item(localized("ui.decision_tree_all_frames"), enabled = hotkeys) { svm?.applyDecisionTreeAll() }
            Item(localized("ui.dt_auto_only"), enabled = hasSession && usesOutliers) { svm?.applyDecisionTreeToCurrentFrame(autoOnly = true) }
            Item(localized("ui.render_this_frame"), enabled = hotkeys) { svm?.renderCurrentFrame() }
            // As the gui's: a run over the sequence with the question about rendering the video (frames already written are skipped), not
            // a separate pass that finished every frame from what was on disk (L4, D7).
            Item(localized("ui.render_all_frames"), enabled = hasSession) { app.requestProcessAll() }
        }

        Menu(localized("menu.tools"), mnemonic = 'T') {
            ToolType.selectable.forEachIndexed { i, t ->
                Item(localized("ui.tool_n", t.displayName, i + 1), enabled = hotkeys) { svm?.setTool(t) }
            }
            Separator()
            // Disabled while the horizon painter is open: Compose delivers a menu accelerator before it delivers the key
            // to the view, so E would switch mode instead of selecting ground, and S or G during the startup painting
            // would leave the painter without its startup flow (macOS disables S there).
            Item(localized("ui.edit_mode"), enabled = hotkeys, shortcut = KeyShortcut(Key.E)) { svm?.setMode(InteractionMode.EDIT) }
            Item(localized("ui.scrub_mode"), enabled = hotkeys, shortcut = KeyShortcut(Key.S)) { svm?.setMode(InteractionMode.SCRUB) }
            Item(localized("ui.grid_mode"), enabled = hotkeys, shortcut = KeyShortcut(Key.G)) { svm?.setMode(InteractionMode.GRID) }
            // The same item closes the painter while it is open, and says so (macOS).
            Item(localized(if (state.paintingHorizon) "ui.close_horizon_painter" else "ui.paint_horizon_reference"), enabled = state.notUnderModal, shortcut = KeyShortcut(Key.H)) {
                svm?.let { if (it.mode.value != InteractionMode.EDIT) it.setMode(InteractionMode.EDIT); it.toggleHorizonPaint() }
            }
            Separator()
            // Tab also does this, but a focused control can take Tab for focus traversal before it gets here, so the menu is the way that always works.
            Item(localized("ui.toggle_side_panels"), enabled = hasSession) { svm?.toggleSidePanels() }
            Item(localized("ui.toggle_filmstrip"), enabled = hasSession) { svm?.toggleFilmstrip() }
            Item(localized("ui.play_pause"), enabled = hotkeys, shortcut = KeyShortcut(Key.Spacebar)) { svm?.playForward() }
        }

        Menu(localized("ui.window"), mnemonic = 'W') {
            Item(localized("ui.blob_processing_window"), shortcut = windowShortcut(Key.P, IS_MAC)) { app.toggleBlobWindow() }
            Item(localized("ui.outlier_information_window"), enabled = hasSession, shortcut = windowShortcut(Key.O, IS_MAC)) { app.toggleOutlierWindow() }
            Item(localized("ui.alignment_information_window"), enabled = hasSession, shortcut = windowShortcut(Key.A, IS_MAC)) { app.toggleAlignmentWindow() }
            Item(localized("ui.debug_window"), shortcut = windowShortcut(Key.D, IS_MAC)) { app.toggleDebugWindow() }
        }

        // The macOS app puts the language in its app menu, which is where a Mac user looks; Compose Desktop has no app menu on Windows or
        // Linux, and this menu bar is shared across all three, so it is a menu of its own (a platform difference, not a command: it is not
        // in commands.json).
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
    }.menus
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
