package com.star.desktop

import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.unit.DpSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Window
import androidx.compose.ui.window.application
import androidx.compose.ui.window.rememberWindowState
import com.star.desktop.ui.app.AppViewModel
import com.star.desktop.ui.app.StarApp
import com.star.desktop.ui.app.StarMenuBar
import com.star.desktop.ui.app.handleGlobalKey
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import com.star.desktop.i18n.localized

/**
 * Compose application entry point. The headless engine smoke harness lives in
 * `com.star.desktop.tools.SmokeHarness` (run via `./gradlew smoke`).
 *
 * `--self-test` runs [com.star.desktop.tools.EngineSelfTest] instead of the UI: the installed
 * launcher, its JVM options and its bundled engine, checked end to end with no window.
 */
fun main(args: Array<String>) {
    if (args.firstOrNull() == "--self-test") {
        kotlin.system.exitProcess(com.star.desktop.tools.EngineSelfTest.run(args.drop(1)))
    }
    runApp(args)
}

private fun runApp(args: Array<String>) = application {
    // App-lifetime scope for the root view model (engine, repositories, progress streams).
    val appScope = remember { CoroutineScope(SupervisorJob() + Dispatchers.Default) }
    // Dev convenience: `./gradlew run --args="/path/to/seq"` opens it on launch.
    // Dev arg form: "<path>", "<path>::<mode>", or "<path>::<mode>::<frame>" (mode = edit/scrub/grid).
    // The "::" separator avoids Gradle's --args splitting a space into a separate task argument.
    val parts = args.firstOrNull()?.split("::") ?: emptyList()
    val openPath = parts.getOrNull(0)?.ifBlank { null }
    val openMode = parts.getOrNull(1)?.ifBlank { null }
    val openFrame = parts.getOrNull(2)?.toIntOrNull()
    val vm = remember { AppViewModel(appScope, autoOpenPath = openPath, autoMode = openMode, autoFrame = openFrame) }
    vm.onQuit = ::exitApplication
    // Cmd-Q (and Quit in the app menu) on a Mac would exit at once; it goes through the same question as the window's close button.
    LaunchedEffect(vm) {
        runCatching {
            if (java.awt.Desktop.isDesktopSupported() && java.awt.Desktop.getDesktop().isSupported(java.awt.Desktop.Action.APP_QUIT_HANDLER)) {
                java.awt.Desktop.getDesktop().setQuitHandler { _, response ->
                    response.cancelQuit()
                    vm.requestQuit()
                }
            }
        }
    }
    // Preferences… in a Mac's app menu (and Cmd-,) is the system's item, which asks the application to open its preferences.
    LaunchedEffect(vm) {
        runCatching {
            if (java.awt.Desktop.isDesktopSupported() && java.awt.Desktop.getDesktop().isSupported(java.awt.Desktop.Action.APP_PREFERENCES)) {
                java.awt.Desktop.getDesktop().setPreferencesHandler { vm.openPreferences() }
            }
        }
    }
    Window(
        onCloseRequest = vm::requestQuit,
        title = "Star",
        state = rememberWindowState(size = DpSize(1280.dp, 800.dp)),
        onKeyEvent = { handleGlobalKey(it, vm) },
    ) {
        StarMenuBar(vm)
        StarApp(vm)
    }

    // Secondary Outlier table window (macOS multi-window behavior), toggled from the Window menu.
    val showOutlier by vm.showOutlierWindow.collectAsState()
    val screen by vm.screen.collectAsState()
    val svm = (screen as? com.star.desktop.ui.app.AppScreen.Sequence)?.vm
    if (showOutlier && svm != null) {
        // "Outliers for frame N", for the frame the table lists (0-based, like everywhere else in the app).
        val listed by svm.infoRows.collectAsState()
        val looking by svm.currentIndex.collectAsState()
        Window(
            onCloseRequest = vm::closeOutlierWindow,
            title = localized("ui.outliers_for_frame", listed?.frameIndex ?: looking),
            state = rememberWindowState(size = DpSize(960.dp, 720.dp)),
        ) {
            com.star.desktop.ui.theme.StarTheme {
                com.star.desktop.ui.windows.OutlierWindowView(svm)
            }
        }
    }

    // Secondary Alignment diagnostics window.
    val showAlign by vm.showAlignmentWindow.collectAsState()
    if (showAlign && svm != null) {
        Window(
            onCloseRequest = vm::closeAlignmentWindow,
            title = localized("ui.alignment_2"),
            state = rememberWindowState(size = DpSize(720.dp, 560.dp)),
        ) {
            com.star.desktop.ui.theme.StarTheme {
                com.star.desktop.ui.windows.AlignmentWindowView(vm, svm)
            }
        }
    }
}
