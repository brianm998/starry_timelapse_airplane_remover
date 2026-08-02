package com.star.desktop.ui.app

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.star.desktop.engine.EngineStatus
import com.star.desktop.ui.initial.InitialView
import com.star.desktop.ui.loading.LoadingView
import com.star.desktop.ui.sequence.SequenceScreen
import com.star.desktop.ui.theme.StarColors
import com.star.desktop.ui.theme.StarShapes
import com.star.desktop.ui.theme.StarTheme

/** Root composable: routes between Initial / Loading / Sequence, with an engine badge and error overlay. */
@Composable
fun StarApp(vm: AppViewModel) {
    StarTheme {
        val screen by vm.screen.collectAsState()
        val error by vm.error.collectAsState()

        Box(Modifier.fillMaxSize().background(StarColors.appBackground)) {
            when (val s = screen) {
                is AppScreen.Initial -> InitialView(vm)
                is AppScreen.Loading -> LoadingView(s.title, s.detail, s.fraction)
                is AppScreen.Sequence -> SequenceScreen(vm, s.vm)
            }

            // On the start/loading screens the badge floats top-right (nothing there to overlap).
            // While a session is open it lives inside the SequenceScreen top bar instead (see TopBar).
            if (screen !is AppScreen.Sequence) {
                EngineBadge(vm, Modifier.align(Alignment.TopEnd).padding(8.dp))
            }

            val showSettings by vm.showSettings.collectAsState()
            if (showSettings && screen is AppScreen.Sequence) {
                com.star.desktop.ui.dialogs.ProcessingSettingsDialog(vm)
            }
            val showRenderVideo by vm.showRenderVideo.collectAsState()
            if (showRenderVideo && screen is AppScreen.Sequence) {
                com.star.desktop.ui.dialogs.RenderVideoDialog(vm)
            }
            val showInfo by vm.showInfoDialog.collectAsState()
            if (showInfo) {
                com.star.desktop.ui.dialogs.InfoDialog(onClose = vm::closeInfoDialog)
            }
            val startupStep by vm.startupStep.collectAsState()
            if (startupStep != null && screen is AppScreen.Sequence) {
                com.star.desktop.ui.dialogs.StartupPrompts(vm, startupStep!!)
            }
            val showPre by vm.showPreRenderPrompt.collectAsState()
            if (showPre && screen is AppScreen.Sequence) com.star.desktop.ui.dialogs.PreProcessingRenderPrompt(vm)
            val showPost by vm.showPostRenderPrompt.collectAsState()
            if (showPost && screen is AppScreen.Sequence) com.star.desktop.ui.dialogs.PostProcessingRenderPrompt(vm)

            val engineWarning by vm.engineWarning.collectAsState()
            engineWarning?.let { w ->
                // Not gated on being in a Sequence screen, unlike the version banner below: an
                // engine that is about to be killed for memory is worth saying wherever the
                // user happens to be.
                EngineWarningBanner(w, onDismiss = vm::dismissEngineWarning,
                                    modifier = Modifier.align(Alignment.TopCenter))
            }

            val versionWarning by vm.versionWarning.collectAsState()
            if (versionWarning != null && screen is AppScreen.Sequence) {
                VersionWarningBanner(versionWarning!!, onDismiss = vm::dismissVersionWarning, modifier = Modifier.align(Alignment.TopCenter))
            }

            val engineDown by vm.engineDown.collectAsState()
            engineDown?.let { EngineDownOverlay(it, onRestart = vm::restartEngine, onClose = vm::dismissEngineDown) }

            error?.let { ErrorOverlay(it, onDismiss = vm::dismissError) }
        }
    }
}

@Composable
private fun EngineDownOverlay(message: String, onRestart: () -> Unit, onClose: () -> Unit) {
    Box(Modifier.fillMaxSize().background(StarColors.scrim), contentAlignment = Alignment.Center) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            modifier = Modifier
                .widthIn(max = 460.dp)
                .clip(StarShapes.errorCard)
                .background(StarColors.prefsCard)
                .padding(32.dp),
        ) {
            Text("Engine stopped", color = StarColors.red, fontSize = 16.sp)
            Text(message, color = StarColors.textSecondary, fontSize = 12.sp, modifier = Modifier.padding(top = 8.dp))
            Text(
                "Restart re-opens this session from its saved config.",
                color = StarColors.textDisabled, fontSize = 11.sp, modifier = Modifier.padding(top = 12.dp),
            )
            androidx.compose.foundation.layout.Row(
                modifier = Modifier.padding(top = 20.dp),
                horizontalArrangement = androidx.compose.foundation.layout.Arrangement.spacedBy(10.dp),
            ) {
                androidx.compose.material3.OutlinedButton(onClick = onClose) { Text("Close Session") }
                Button(onClick = onRestart) { Text("Restart Engine") }
            }
        }
    }
}

/**
 * A warning the daemon pushed about the machine — memory pressure, output it could not write,
 * a disk with no room.
 *
 * Red for `critical`, which for memory pressure means the OS is about to start killing things
 * and the user has seconds to close something; yellow otherwise. Dismissible, because a
 * warning the user cannot get rid of is one they will learn to ignore — and the next one
 * raises it again anyway.
 */
@Composable
private fun EngineWarningBanner(
    warning: com.star.proto.Warning,
    onDismiss: () -> Unit,
    modifier: Modifier,
) {
    val background = if (warning.severity == "critical") StarColors.red else StarColors.yellow
    androidx.compose.foundation.layout.Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = modifier
            .padding(8.dp)
            .widthIn(max = 640.dp)
            .clip(RoundedCornerShape(8.dp))
            .background(background.copy(alpha = 0.94f))
            .padding(horizontal = 12.dp, vertical = 6.dp),
    ) {
        Column(Modifier.weight(1f, fill = false)) {
            Text("⚠  ${warning.title}", color = Color.Black, fontSize = 12.sp)
            Text(warning.message, color = Color.Black, fontSize = 11.sp)
            if (warning.suggestion.isNotEmpty()) {
                Text(warning.suggestion, color = Color.Black.copy(alpha = 0.75f), fontSize = 11.sp)
            }
        }
        androidx.compose.material3.TextButton(onClick = onDismiss) { Text("Dismiss", fontSize = 12.sp) }
    }
}

@Composable
private fun VersionWarningBanner(message: String, onDismiss: () -> Unit, modifier: Modifier) {
    androidx.compose.foundation.layout.Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = modifier
            .padding(8.dp)
            .clip(RoundedCornerShape(8.dp))
            .background(StarColors.yellow.copy(alpha = 0.92f))
            .padding(horizontal = 12.dp, vertical = 6.dp),
    ) {
        Text("⚠  $message", color = Color.Black, fontSize = 12.sp)
        androidx.compose.material3.TextButton(onClick = onDismiss) { Text("Dismiss", fontSize = 12.sp) }
    }
}

/**
 * The engine-failure reason condensed to fit a badge.
 *
 * [DaemonProcess.deathDescription] returns a full sentence plus, where there was one, the
 * daemon's last meaningful stderr line. That belongs in the overlay; the badge needs three or
 * four words, and the distinction that matters most at a glance is "killed" versus "stopped".
 */
internal fun shortEngineFailure(message: String): String = when {
    message.contains("out of memory") -> "engine killed: out of memory"
    message.contains("SIGKILL") -> "engine killed"
    message.contains("crashed") -> "engine crashed"
    message.contains("exited normally") -> "engine exited"
    else -> "engine stopped"
}

@Composable
fun EngineBadge(vm: AppViewModel, modifier: Modifier = Modifier) {
    val status by vm.engineStatus.collectAsState()
    val (color, label) = when (val s = status) {
        is EngineStatus.Connected -> StarColors.green to "engine ${s.daemonVersion}"
        EngineStatus.Connecting -> StarColors.yellow to "connecting…"
        EngineStatus.Disconnected -> StarColors.gray to "disconnected"
        // The badge has room for a few words, not a sentence, so it stays short — but the
        // reason is no longer thrown away: it is in the tooltip here and in full in the
        // engine-down overlay. Discarding `s.message` for a literal was why a daemon killed
        // for memory and one that quit cleanly looked identical.
        is EngineStatus.Failed -> StarColors.red to shortEngineFailure(s.message)
    }
    androidx.compose.foundation.layout.Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = modifier
            .clip(RoundedCornerShape(10.dp))
            .background(StarColors.appBackground.copy(alpha = 0.7f))
            .padding(horizontal = 8.dp, vertical = 4.dp),
    ) {
        Box(Modifier.size(8.dp).clip(CircleShape).background(color))
        Text("  $label", color = StarColors.textSecondary, fontSize = 10.sp)
    }
}

@Composable
private fun ErrorOverlay(message: String, onDismiss: () -> Unit) {
    Box(Modifier.fillMaxSize().background(StarColors.scrim), contentAlignment = Alignment.Center) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            modifier = Modifier
                .widthIn(max = 500.dp)
                .clip(StarShapes.errorCard)
                .background(StarColors.red.copy(alpha = 0.92f))
                .padding(40.dp),
        ) {
            Text(message, color = Color.White, fontSize = 14.sp)
            Button(onClick = onDismiss, modifier = Modifier.padding(top = 20.dp)) { Text("Dismiss") }
        }
    }
}
