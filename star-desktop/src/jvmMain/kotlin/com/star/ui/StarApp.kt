package com.star.ui

import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.star.engine.EngineStatus
import com.star.ui.theme.StarTheme
import com.star.viewmodel.AppViewModel
import kotlinx.coroutines.MainScope
import kotlinx.coroutines.launch

/**
 * Root composable — mirrors ContentView.swift / ViewModel.swift.
 * Switches between InitialView and MainView based on session state.
 * Hosts the menu bar (StarMenuBar.kt).
 */
@Composable
fun StarApp(appViewModel: AppViewModel) {
    StarTheme {
        val engineStatus by appViewModel.engineStatus.collectAsState()
        val sequenceViewModel by appViewModel.sequenceViewModel.collectAsState()
        val error by appViewModel.error.collectAsState()

        Box(Modifier.fillMaxSize()) {
            when {
                sequenceViewModel != null -> {
                    val seqVm = sequenceViewModel!!
                    val mode by appViewModel.interactionMode.collectAsState()
                    MainView(
                        appViewModel = appViewModel,
                        sequenceViewModel = seqVm,
                        interactionMode = mode,
                    )
                }
                else -> {
                    InitialView(
                        prefs = appViewModel.prefs,
                        engineStatus = engineStatus,
                        onOpenSequence = { dir ->
                            MainScope().launch { appViewModel.openSequence(dir) }
                        },
                        onOpenConfig = { path ->
                            MainScope().launch { appViewModel.openConfig(path) }
                        },
                        onOpenVideo = { path -> appViewModel.openVideo(path) },
                        onRestartEngine = { appViewModel.restartEngine() },
                    )
                }
            }

            // Error snackbar
            val errorMsg = error
            if (errorMsg != null) {
                Snackbar(
                    modifier = Modifier.align(Alignment.BottomCenter).padding(16.dp),
                    action = {
                        TextButton(onClick = { appViewModel.clearError() }) {
                            Text("Dismiss")
                        }
                    },
                ) {
                    Text(errorMsg)
                }
            }
        }
    }
}
