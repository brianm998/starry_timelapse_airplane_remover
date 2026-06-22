package com.star

import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.*
import com.star.data.LocalPreferences
import com.star.engine.DaemonProcess
import com.star.engine.EngineState
import com.star.ui.StarApp
import com.star.viewmodel.AppViewModel

fun main() = application {
    val prefs = LocalPreferences()
    val engine = EngineState(
        binaryPath = try {
            DaemonProcess.resolveStardBinary()
        } catch (e: Exception) {
            // Allow the app to start even without stard — engine status will show Failed.
            System.err.println("Warning: ${e.message}")
            "stard"  // placeholder; engine.start() will fail gracefully
        },
        scratchDir = DaemonProcess.defaultScratchDir(),
    )

    val appViewModel = AppViewModel(engine = engine, prefs = prefs)
    appViewModel.startEngine()

    val windowState = rememberWindowState(width = prefs.windowWidth.dp, height = prefs.windowHeight.dp)

    Window(
        onCloseRequest = {
            appViewModel.onCleared()
            exitApplication()
        },
        title = "Star",
        state = windowState,
    ) {
        StarApp(appViewModel = appViewModel)
    }
}
