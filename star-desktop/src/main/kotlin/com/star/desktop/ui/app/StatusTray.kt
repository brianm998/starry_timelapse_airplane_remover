package com.star.desktop.ui.app

import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.painter.Painter
import androidx.compose.ui.window.ApplicationScope
import androidx.compose.ui.window.Tray
import com.star.desktop.domain.FrameStateCounts
import com.star.desktop.domain.MenuBarStatus
import com.star.desktop.domain.StepRateTracker
import com.star.desktop.domain.StepRow
import com.star.desktop.domain.isRendering
import com.star.desktop.domain.RenderState
import com.star.desktop.i18n.localized
import com.star.desktop.ui.dialogs.hasPlan

/**
 * The system-tray icon: the same live run status as the macOS menu-bar wand, readable from any app without bringing star forward. Status only: a
 * tray menu here holds text, so the lines are disabled items and the progress bar is drawn in block characters ([MenuBarStatus.textBar]).
 *
 * It reads the StateFlows the processing screen reads and recomposes when they move: no timer, no polling, and nothing runs between changes. Where
 * the platform has no tray (some Linux desktops) there is no icon, and nothing else changes.
 */
@Composable
fun ApplicationScope.StatusTray(app: AppViewModel) {
    if (!isTraySupported) return
    val screen by app.screen.collectAsState()
    val session by app.sessions.session.collectAsState()
    val renderState by app.renderState.collectAsState()
    val svm = (screen as? AppScreen.Sequence)?.vm

    val processing = svm?.isProcessing?.collectAsState()?.value == true
    val report = svm?.stepProgress?.collectAsState()?.value
    val frameStates = svm?.frameStates?.collectAsState()?.value
    val extraction = svm?.extraction?.collectAsState()?.value
    val rows = StepRow.of(report)
    // One tracker per run, replaced when a run starts so the last one's samples are gone; fed as the counts change, as the processing screen does.
    val rates = remember(svm, processing) { StepRateTracker() }
    if (processing) rates.observe(rows)

    val status = MenuBarStatus.of(
        sequenceName = if (svm != null) session?.config?.imageSequenceDirname else null,
        isProcessing = processing,
        isRendering = renderState.isRendering,
        renderFraction = (renderState as? RenderState.Rendering)?.fraction ?: 0f,
        steps = rows,
        extraction = extraction,
        hasPlan = hasPlan(report),
        statusText = report?.status?.takeIf { it.isNotEmpty() },
        framesComplete = if (svm != null && frameStates != null) FrameStateCounts(frameStates, svm.frameCount).complete else 0,
        frameCount = svm?.frameCount ?: 0,
        secondsRemaining = { rates.secondsRemaining(it) },
    )

    Tray(icon = remember { StarTrayIcon }, tooltip = localized("ui.star")) {
        for (line in status.lines()) Item(line, enabled = false, onClick = {})
    }
}

/** A four-pointed star, drawn in code: the app has no tray-sized image resource. */
private object StarTrayIcon : Painter() {
    override val intrinsicSize = Size(32f, 32f)

    override fun DrawScope.onDraw() {
        val c = Offset(size.width / 2, size.height / 2)
        val long = size.minDimension / 2
        val short = long * 0.28f
        val path = Path().apply {
            moveTo(c.x, c.y - long)
            lineTo(c.x + short, c.y - short)
            lineTo(c.x + long, c.y)
            lineTo(c.x + short, c.y + short)
            lineTo(c.x, c.y + long)
            lineTo(c.x - short, c.y + short)
            lineTo(c.x - long, c.y)
            lineTo(c.x - short, c.y - short)
            close()
        }
        drawPath(path, Color(0.85f, 0.85f, 0.85f))
    }
}
