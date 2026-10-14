package com.star.desktop.ui.dialogs

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.star.desktop.ui.app.AppViewModel
import com.star.desktop.ui.theme.StarColors
import com.star.desktop.ui.theme.StarShapes
import com.star.proto.ProgressEvent
import com.star.proto.VideoCapabilities
import com.star.proto.VideoEncodeSettings
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import com.star.desktop.i18n.localized

/**
 * Render Video sheet (macOS `RenderVideoSheetView`): cascading pickers driven by
 * `Export.GetVideoCapabilities` (codec → encoder → pixel format / muxer, plus frame rate), then
 * `Export.Video`. Stops the live processing-progress subscription first, since the daemon shares one
 * progress slot per session.
 */
@Composable
fun RenderVideoDialog(app: AppViewModel) {
    val scope = rememberCoroutineScope()
    val caps by produceState<VideoCapabilities?>(null) { value = runCatching { app.export.capabilities() }.getOrNull() }
    // Whether a render is under way, for the scrim as well as the buttons: clicking outside used to close the
    // dialog while ffmpeg went on writing the video.
    var rendering by remember { mutableStateOf(false) }

    Box(
        Modifier.fillMaxSize().background(StarColors.scrim).clickable(enabled = !rendering, onClick = app::closeRenderVideo),
        contentAlignment = Alignment.Center,
    ) {
        Column(
            modifier = Modifier
                .widthIn(max = 520.dp)
                .clip(StarShapes.card)
                .background(StarColors.prefsCard)
                .clickable(enabled = false) {}
                .padding(24.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text(localized("ui.render_video"), color = StarColors.textPrimary, fontWeight = FontWeight.SemiBold, fontSize = 18.sp)

            val c = caps
            if (c == null) {
                Text(localized("ui.loading_codecs"), color = StarColors.textSecondary, fontSize = 13.sp)
                return@Column
            }

            // Start from the settings the session already has (the video it was imported from, else its
            // config), not the first entry of every list; each level is checked against what the one above allows.
            val stored = remember(c) { storedVideoSettings(app.sessions.session.value) }
            var choice by remember(c) { mutableStateOf(resolveVideoChoice(c, stored)) }
            val codecs = c.codecsList
            val encoders = codecs.firstOrNull { it.codec == choice.codec }?.encodersList ?: emptyList()
            val encCaps = encoders.firstOrNull { it.encoder == choice.encoder }
            val pixelFormats = encCaps?.pixelFormatsList ?: emptyList()
            val muxers = encCaps?.muxersList ?: emptyList()
            val frameRates = c.frameRatesList

            Picker("Codec", codecs.map { it.codec }, choice.codec) { choice = choice.withCodec(c, it) }
            Picker("Encoder", encoders.map { it.encoder }, choice.encoder) { choice = choice.withEncoder(c, it) }
            Picker("Pixel format", pixelFormats, choice.pixelFormat) { choice = choice.copy(pixelFormat = it) }
            Picker("Container (muxer)", muxers, choice.muxer) { choice = choice.copy(muxer = it) }
            // The rate in use is listed even when it is not one of the standard ones (29.97 from an import).
            val rateOptions = (frameRates + choice.frameRate).distinct()
            Picker("Frame rate", rateOptions.map { it.toString() }, choice.frameRate.toString()) {
                choice = choice.copy(frameRate = it.toDoubleOrNull() ?: choice.frameRate)
            }

            var status by remember { mutableStateOf<String?>(null) }
            var progress by remember { mutableStateOf<Float?>(null) }
            var renderJob by remember { mutableStateOf<Job?>(null) }

            fun doRender() {
                val sid = app.sessions.sessionId ?: return
                if (rendering || choice.encoder.isEmpty()) return
                // Said once, here: the dialog is not asked to start again by the render prompt's "Yes" after this.
                app.consumeRenderVideoAutoStart()
                rendering = true
                status = "Rendering…"
                progress = null
                val settings = choice.toSettings()
                renderJob = scope.launch {
                    try {
                        app.export.exportVideo(sid, "", settings).collect { ev ->
                            if (ev.kindCase == ProgressEvent.KindCase.IO_PROGRESS) {
                                val io = ev.ioProgress
                                progress = if (io.total > 0) io.current.toFloat() / io.total else null
                                status = "Rendering ${io.current} / ${io.total}"
                            }
                        }
                        status = "Done"
                    } catch (e: kotlinx.coroutines.CancellationException) {
                        status = "Cancelled"   // the user stopped it: the daemon has stopped ffmpeg and removed the partial file
                        throw e
                    } catch (e: Throwable) {
                        status = "Error: ${e.message}"
                    } finally {
                        rendering = false
                        renderJob = null
                    }
                }
            }

            // Auto-start when opened from the render prompt's "Yes" (once codecs + a default encoder load).
            // consumeRenderVideoAutoStart() clears the flag as the render begins, so changing the codec afterwards
            // does not start another.
            val autoStart by app.renderVideoAutoStart.collectAsState()
            LaunchedEffect(autoStart, choice.encoder) { if (autoStart && !rendering && choice.encoder.isNotEmpty()) doRender() }

            status?.let { Text(it, color = StarColors.textSecondary, fontSize = 12.sp) }
            if (rendering) LinearProgressIndicator(progress = { progress ?: 0f }, modifier = Modifier.fillMaxWidth(), color = StarColors.accent)

            Row(Modifier.fillMaxWidth().padding(top = 8.dp), horizontalArrangement = Arrangement.spacedBy(10.dp, Alignment.End)) {
                // While rendering this is the way to stop it: cancelling the request makes the daemon terminate ffmpeg.
                OutlinedButton(onClick = { if (rendering) renderJob?.cancel() else app.closeRenderVideo() }) { Text(localized("ui.cancel")) }
                Button(
                    enabled = !rendering && choice.encoder.isNotEmpty(),
                    onClick = { doRender() },
                    colors = ButtonDefaults.buttonColors(containerColor = StarColors.accent),
                ) { Text(localized("ui.render")) }
            }
        }
    }
}

@Composable
private fun Picker(label: String, options: List<String>, selected: String, onSelect: (String) -> Unit) {
    var expanded by remember { mutableStateOf(false) }
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.SpaceBetween) {
        Text(label, color = StarColors.textSecondary, fontSize = 12.sp)
        Box {
            Box(
                Modifier
                    .width(260.dp)
                    .clip(StarShapes.picker)
                    .background(StarColors.cellDefault)
                    .clickable(enabled = options.isNotEmpty()) { expanded = true }
                    .padding(horizontal = 10.dp, vertical = 6.dp),
            ) {
                Text(
                    selected.ifEmpty { "—" },
                    color = StarColors.textPrimary, fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis,
                )
            }
            DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
                options.forEach { opt ->
                    DropdownMenuItem(
                        text = { Text(opt, color = if (opt == selected) StarColors.accent else StarColors.textPrimary, fontSize = 12.sp) },
                        onClick = { onSelect(opt); expanded = false },
                    )
                }
            }
        }
    }
}
