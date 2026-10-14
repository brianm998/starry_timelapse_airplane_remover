package com.star.desktop.ui.app

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.star.desktop.engine.EngineFailure
import com.star.desktop.engine.EngineStatus
import com.star.desktop.ui.dialogs.PromptCard
import com.star.desktop.ui.initial.InitialView
import com.star.desktop.ui.loading.LoadingView
import com.star.desktop.ui.sequence.SequenceScreen
import com.star.desktop.ui.theme.StarColors
import com.star.desktop.ui.theme.StarShapes
import com.star.desktop.ui.theme.StarTheme
import com.star.desktop.i18n.localized

/** Root composable: routes between Initial / Loading / Sequence, with an engine badge and error overlay. */
@Composable
fun StarApp(vm: AppViewModel) {
    StarTheme {
        val screen by vm.screen.collectAsState()
        val error by vm.error.collectAsState()

        Box(Modifier.fillMaxSize().background(StarColors.appBackground)) {
            when (val s = screen) {
                is AppScreen.Initial -> InitialView(vm)
                is AppScreen.Loading -> LoadingView(localized(s.titleKey), s.detail, s.fraction)
                is AppScreen.Opening -> com.star.desktop.ui.loading.OpeningView(s.progress, onCancel = vm::cancelOpen)
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
            val showPreferences by vm.showPreferences.collectAsState()
            if (showPreferences) com.star.desktop.ui.dialogs.PreferencesDialog(vm)
            val showRenderVideo by vm.showRenderVideo.collectAsState()
            if (showRenderVideo && screen is AppScreen.Sequence) {
                com.star.desktop.ui.dialogs.RenderVideoDialog(vm)
            }
            val showInfo by vm.showInfoDialog.collectAsState()
            if (showInfo) {
                val infoType by vm.currentInfoType.collectAsState()
                com.star.desktop.ui.dialogs.InfoDialog(selected = infoType, onSelect = vm::setInfoType, onClose = vm::closeInfoDialog)
            }
            // Told once, at launch, on the start screen (macOS shows its sheet from the same place).
            val newRelease by vm.newRelease.collectAsState()
            newRelease?.let { release ->
                if (screen is AppScreen.Initial) {
                    com.star.desktop.ui.dialogs.NewReleaseDialog(release, vm.runningVersion.orEmpty(), onLater = vm::dismissNewRelease, onQuit = vm::requestQuit)
                }
            }
            val startupStep by vm.startupStep.collectAsState()
            if (startupStep != null && screen is AppScreen.Sequence) {
                com.star.desktop.ui.dialogs.StartupPrompts(vm, startupStep!!)
            }
            val sequenceProgress by vm.sequenceProgress.collectAsState()
            sequenceProgress?.let { if (screen is AppScreen.Sequence) com.star.desktop.ui.dialogs.SequenceProgressDialog(vm, it) }
            val showPre by vm.showPreRenderPrompt.collectAsState()
            if (showPre && screen is AppScreen.Sequence) com.star.desktop.ui.dialogs.PreProcessingRenderPrompt(vm)
            val showPost by vm.showPostRenderPrompt.collectAsState()
            if (showPost && screen is AppScreen.Sequence) com.star.desktop.ui.dialogs.PostProcessingRenderPrompt(vm)
            if (screen is AppScreen.Sequence) {
                val sequenceVm = (screen as AppScreen.Sequence).vm
                val showProcessingModal by sequenceVm.showProcessingModal.collectAsState()
                if (showProcessingModal) com.star.desktop.ui.dialogs.ProcessingModal(vm, sequenceVm)
            }

            // Over everything but the engine's own failure: leaving with work going is asked about wherever the user happens to be.
            val closeConfirmation by vm.closeConfirmation.collectAsState()
            closeConfirmation?.let { ConfirmCloseOverlay(it, onConfirm = vm::confirmClose, onCancel = vm::cancelClose) }

            // The banners, one above the other in one column so that none covers another: the engine's warning (not gated on a sequence being
            // open: an engine about to be killed for memory is worth saying wherever the user is), and the version mismatch.
            val warnings by vm.warningState.collectAsState()
            val versionWarning by vm.versionWarning.collectAsState()
            val showVersion = versionWarning != null && screen is AppScreen.Sequence
            if (warnings.banner != null || showVersion) {
                Column(Modifier.align(Alignment.TopCenter)) {
                    warnings.banner?.let { EngineWarningBanner(it.warning, onDismiss = vm::dismissBanner, modifier = Modifier) }
                    if (showVersion) VersionWarningBanner(versionWarning!!, onDismiss = vm::dismissVersionWarning, modifier = Modifier)
                }
            }
            // A critical warning interrupts, once per kind (see WarningRouting).
            warnings.critical?.let { CriticalWarningDialog(it, onOk = vm::acknowledgeWarning, onRestart = vm::restartAbandonedRun) }

            val engineDown by vm.engineDown.collectAsState()
            engineDown?.let {
                EngineDownOverlay(it, sessionOpen = screen is AppScreen.Sequence,
                                  onRestart = vm::restartEngine, onClose = vm::dismissEngineDown)
            }

            error?.let { ErrorOverlay(it, onDismiss = vm::dismissError) }
        }
    }
}

@Composable
private fun EngineDownOverlay(message: String, sessionOpen: Boolean, onRestart: () -> Unit, onClose: () -> Unit) {
    Box(Modifier.fillMaxSize().background(StarColors.scrim), contentAlignment = Alignment.Center) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            modifier = Modifier
                .widthIn(max = 460.dp)
                .clip(StarShapes.errorCard)
                .background(StarColors.prefsCard)
                .padding(32.dp),
        ) {
            Text(localized("ui.engine_stopped"), color = StarColors.red, fontSize = 16.sp)
            // Selectable, because the reason (and the engine log path at its end) is exactly what a
            // user has to copy into a bug report.
            androidx.compose.foundation.text.selection.SelectionContainer {
                Text(message, color = StarColors.textSecondary, fontSize = 12.sp, modifier = Modifier.padding(top = 8.dp))
            }
            if (sessionOpen) {
                Text(
                    localized("ui.restart_re_opens_this_session_from_its_saved"),
                    color = StarColors.textDisabled, fontSize = 11.sp, modifier = Modifier.padding(top = 12.dp),
                )
            }
            androidx.compose.foundation.layout.Row(
                modifier = Modifier.padding(top = 20.dp),
                horizontalArrangement = androidx.compose.foundation.layout.Arrangement.spacedBy(10.dp),
            ) {
                androidx.compose.material3.OutlinedButton(onClick = onClose) {
                    Text(localized(if (sessionOpen) "ui.close_session" else "ui.dismiss"))
                }
                Button(onClick = onRestart) { Text(localized("ui.restart_engine")) }
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
            Text(localized("ui.warning_banner", warning.title), color = Color.Black, fontSize = 12.sp)
            Text(warning.message, color = Color.Black, fontSize = 11.sp)
            if (warning.suggestion.isNotEmpty()) {
                Text(warning.suggestion, color = Color.Black.copy(alpha = 0.75f), fontSize = 11.sp)
            }
        }
        androidx.compose.material3.TextButton(onClick = onDismiss) { Text(localized("ui.dismiss"), fontSize = 12.sp) }
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
        Text(localized("ui.warning_banner", message), color = Color.Black, fontSize = 12.sp)
        androidx.compose.material3.TextButton(onClick = onDismiss) { Text(localized("ui.dismiss"), fontSize = 12.sp) }
    }
}

/**
 * The engine-failure reason condensed to fit a badge.
 *
 * [DaemonProcess.deathDescription] returns a full sentence plus, where there was one, the daemon's last meaningful stderr line. That belongs
 * in the overlay; the badge needs three or four words, and the distinction that matters most at a glance is "killed" versus "stopped".
 */
internal fun shortEngineFailure(failure: EngineFailure): String = localized(
    when (failure) {
        EngineFailure.OUT_OF_MEMORY -> "ui.engine_badge.out_of_memory"
        EngineFailure.CRASHED -> "ui.engine_badge.crashed"
        EngineFailure.EXITED -> "ui.engine_badge.exited"
        EngineFailure.STOPPED -> "ui.engine_badge.stopped"
    },
)

@Composable
fun EngineBadge(vm: AppViewModel, modifier: Modifier = Modifier) {
    val status by vm.engineStatus.collectAsState()
    val (color, label) = when (val s = status) {
        is EngineStatus.Connected -> StarColors.green to localized("ui.engine_badge.connected", s.daemonVersion)
        EngineStatus.Connecting -> StarColors.yellow to localized("ui.engine_badge.connecting")
        EngineStatus.Disconnected -> StarColors.gray to localized("ui.engine_badge.disconnected")
        // The badge has room for a few words, not a sentence, so it stays short — but the
        // reason is no longer thrown away: it is in the tooltip here and in full in the
        // engine-down overlay. Discarding `s.message` for a literal was why a daemon killed
        // for memory and one that quit cleanly looked identical.
        is EngineStatus.Failed -> StarColors.red to shortEngineFailure(s.failure)
    }
    androidx.compose.foundation.layout.Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = modifier
            .clip(RoundedCornerShape(10.dp))
            .background(StarColors.appBackground.copy(alpha = 0.7f))
            .padding(horizontal = 8.dp, vertical = 4.dp),
    ) {
        Box(Modifier.size(8.dp).clip(CircleShape).background(color))
        Text("  " + label, color = StarColors.textSecondary, fontSize = 10.sp)
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
            Text(localized("ui.error"), color = Color.White, fontSize = 18.sp, fontWeight = FontWeight.Bold,
                modifier = Modifier.padding(bottom = 12.dp))
            androidx.compose.foundation.text.selection.SelectionContainer {
                Text(
                    message, color = Color.White, fontSize = 14.sp,
                    modifier = Modifier.heightIn(max = 320.dp).verticalScroll(rememberScrollState()),
                )
            }
            Button(onClick = onDismiss, modifier = Modifier.padding(top = 20.dp)) { Text(localized("ui.close")) }
        }
    }
}

/**
 * "Work In Progress" (macOS alert on quit, on closing the window and on File ▸ Close): what is going on, and a choice between Cancel, which is Esc
 * and Return and leaves it going, and the red button that interrupts it. A click outside does nothing.
 */
@Composable
private fun ConfirmCloseOverlay(confirmation: com.star.desktop.domain.CloseConfirmation, onConfirm: () -> Unit, onCancel: () -> Unit) {
    PromptCard(onScrimClick = null, onDefaultAction = onCancel, onEscape = onCancel) {
        Text(localized("ui.work_in_progress"), color = StarColors.textPrimary, fontWeight = androidx.compose.ui.text.font.FontWeight.SemiBold, fontSize = 18.sp)
        Text(confirmation.message, color = StarColors.textSecondary, fontSize = 13.sp)
        androidx.compose.foundation.layout.Row(
            Modifier.fillMaxWidth().padding(top = 8.dp),
            horizontalArrangement = androidx.compose.foundation.layout.Arrangement.spacedBy(12.dp, Alignment.End),
        ) {
            OutlinedButton(onClick = onCancel) { Text(localized("ui.cancel")) }
            OutlinedButton(onClick = onConfirm, colors = ButtonDefaults.outlinedButtonColors(contentColor = StarColors.red)) {
                Text(localized(confirmation.action.confirmKey))
            }
        }
    }
}

/**
 * A critical warning over the window (macOS's system alert for them): the machine is about to stop this run, or a previous run was stopped. OK is the
 * default, and does nothing but acknowledge it: starting a run that may take hours is not what a stray Return on a dialog the user did not ask for
 * should do; a report of a run that was killed also offers Restart Now. A click outside does nothing.
 */
@Composable
private fun CriticalWarningDialog(warning: com.star.proto.Warning, onOk: () -> Unit, onRestart: (String) -> Unit) {
    PromptCard(onScrimClick = null, onDefaultAction = onOk, onEscape = null) {
        Text(warning.title, color = StarColors.red, fontWeight = androidx.compose.ui.text.font.FontWeight.SemiBold, fontSize = 18.sp)
        Text(warning.message, color = StarColors.textPrimary, fontSize = 13.sp)
        if (warning.suggestion.isNotEmpty()) Text(warning.suggestion, color = StarColors.textSecondary, fontSize = 12.sp)
        androidx.compose.foundation.layout.Row(
            Modifier.fillMaxWidth().padding(top = 8.dp),
            horizontalArrangement = androidx.compose.foundation.layout.Arrangement.spacedBy(12.dp, Alignment.End),
        ) {
            // Only the report of a run that stopped, and only one whose config is still on disk, has anything to restart: the others are about the
            // machine, where there is nothing to pick back up.
            if (warning.restartableConfigPath.isNotEmpty()) {
                OutlinedButton(onClick = { onRestart(warning.restartableConfigPath) }) { Text(localized("ui.restart_now")) }
            }
            Button(onClick = onOk, colors = ButtonDefaults.buttonColors(containerColor = StarColors.accent)) { Text(localized("ui.ok")) }
        }
    }
}
