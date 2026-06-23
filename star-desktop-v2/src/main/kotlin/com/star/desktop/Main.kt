package com.star.desktop

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

/**
 * Compose application entry point. The headless engine smoke harness lives in
 * `com.star.desktop.tools.SmokeHarness` (run via `./gradlew smoke`).
 */
fun main(args: Array<String>) = application {
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
    Window(
        onCloseRequest = ::exitApplication,
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
        Window(
            onCloseRequest = vm::closeOutlierWindow,
            title = "Outliers",
            state = rememberWindowState(size = DpSize(560.dp, 480.dp)),
        ) {
            com.star.desktop.ui.theme.StarTheme {
                com.star.desktop.ui.windows.OutlierWindowView(svm)
            }
        }
    }
}
