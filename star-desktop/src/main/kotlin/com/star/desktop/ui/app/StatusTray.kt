package com.star.desktop.ui.app

import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.ui.graphics.drawscope.Stroke
import com.star.desktop.domain.MenuBarIcon
import com.star.desktop.domain.ringStep
import com.star.desktop.domain.tooltip
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
import androidx.compose.ui.window.isTraySupported
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

    val outcome by app.menuBarOutcome.collectAsState()
    val icon = MenuBarIcon.of(status, outcome.outcome)
    val ringStep = status.ringStep
    // Redrawn only when the look or the 5% step changes: no timer.
    val painter = remember(icon, ringStep) { StarTrayIcon(icon, ringStep) }

    Tray(icon = painter, tooltip = status.tooltip(outcome.outcome)) {
        for (line in status.lines()) Item(line, enabled = false, onClick = {})
    }

    // Compose's Tray has no menu-open callback, so listen on the AWT tray icon it registers.
    DisposableEffect(Unit) {
        val listener = object : java.awt.event.MouseAdapter() {
            override fun mousePressed(e: java.awt.event.MouseEvent) = app.menuOpened()
            override fun mouseReleased(e: java.awt.event.MouseEvent) = app.menuOpened()
        }
        val icons = runCatching { java.awt.SystemTray.getSystemTray().trayIcons.toList() }.getOrDefault(emptyList())
        icons.forEach { it.addMouseListener(listener) }
        onDispose { icons.forEach { it.removeMouseListener(listener) } }
    }
}

/**
 * The tray icon, drawn in code: the app has no tray-sized image resource. A mid-grey fill with a thin dark outline reads on light and dark trays.
 * Idle is the star; running adds a progress ring filled to [ringStep] twentieths; finished and failed add a check or a warning triangle.
 */
private class StarTrayIcon(private val look: MenuBarIcon, private val ringStep: Int) : Painter() {
    override val intrinsicSize = Size(32f, 32f)

    override fun DrawScope.onDraw() {
        val fill = Color(0.62f, 0.62f, 0.62f)
        val outline = Color(0.1f, 0.1f, 0.1f, 0.9f)
        val c = Offset(size.width / 2, size.height / 2)
        val u = size.minDimension
        val starScale = if (look == MenuBarIcon.IDLE) 0.5f else 0.34f
        val long = u * starScale
        val short = long * 0.28f
        val star = Path().apply {
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
        drawPath(star, fill)
        drawPath(star, outline, style = Stroke(width = u * 0.04f))
        when (look) {
            MenuBarIcon.IDLE -> Unit
            MenuBarIcon.RUNNING -> {
                val r = u * 0.45f
                val tl = Offset(c.x - r, c.y - r)
                val box = Size(2 * r, 2 * r)
                drawArc(outline, 0f, 360f, false, tl, box, style = Stroke(width = u * 0.16f))
                if (ringStep > 0) drawArc(fill, -90f, 360f * ringStep / 20, false, tl, box, style = Stroke(width = u * 0.1f))
            }
            MenuBarIcon.FINISHED -> {
                val b = Offset(u * 0.78f, u * 0.78f)
                drawCircle(Color(0.2f, 0.65f, 0.3f), u * 0.2f, b)
                drawCircle(outline, u * 0.2f, b, style = Stroke(width = u * 0.03f))
                val check = Path().apply {
                    moveTo(b.x - u * 0.1f, b.y); lineTo(b.x - u * 0.02f, b.y + u * 0.08f); lineTo(b.x + u * 0.11f, b.y - u * 0.08f)
                }
                drawPath(check, Color.White, style = Stroke(width = u * 0.05f))
            }
            MenuBarIcon.FAILED -> {
                val b = Offset(u * 0.78f, u * 0.76f)
                val tri = Path().apply {
                    moveTo(b.x, b.y - u * 0.22f); lineTo(b.x + u * 0.22f, b.y + u * 0.18f); lineTo(b.x - u * 0.22f, b.y + u * 0.18f); close()
                }
                drawPath(tri, Color(0.9f, 0.7f, 0.1f))
                drawPath(tri, outline, style = Stroke(width = u * 0.03f))
                drawLine(outline, Offset(b.x, b.y - u * 0.08f), Offset(b.x, b.y + u * 0.05f), strokeWidth = u * 0.04f)
                drawCircle(outline, u * 0.02f, Offset(b.x, b.y + u * 0.12f))
            }
        }
    }
}
