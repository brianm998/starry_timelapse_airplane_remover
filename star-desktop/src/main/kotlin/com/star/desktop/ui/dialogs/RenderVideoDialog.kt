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
import com.star.desktop.ui.app.AppScreen
import com.star.desktop.ui.app.AppViewModel
import com.star.desktop.ui.theme.StarColors
import com.star.desktop.ui.theme.StarShapes
import com.star.proto.ProgressEvent
import com.star.proto.VideoCapabilities
import com.star.proto.VideoEncodeSettings
import kotlinx.coroutines.launch

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

    Box(Modifier.fillMaxSize().background(StarColors.scrim).clickable(onClick = app::closeRenderVideo), contentAlignment = Alignment.Center) {
        Column(
            modifier = Modifier
                .widthIn(max = 520.dp)
                .clip(StarShapes.card)
                .background(StarColors.prefsCard)
                .clickable(enabled = false) {}
                .padding(24.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text("Render Video", color = StarColors.textPrimary, fontWeight = FontWeight.SemiBold, fontSize = 18.sp)

            val c = caps
            if (c == null) {
                Text("Loading codecs…", color = StarColors.textSecondary, fontSize = 13.sp)
                return@Column
            }

            val codecs = c.codecsList
            var codec by remember(c) { mutableStateOf(codecs.firstOrNull()?.codec ?: "") }
            val encoders = codecs.firstOrNull { it.codec == codec }?.encodersList ?: emptyList()
            var encoder by remember(codec) { mutableStateOf(encoders.firstOrNull()?.encoder ?: "") }
            val encCaps = encoders.firstOrNull { it.encoder == encoder }
            val pixelFormats = encCaps?.pixelFormatsList ?: emptyList()
            val muxers = encCaps?.muxersList ?: emptyList()
            var pixelFormat by remember(encoder) { mutableStateOf(pixelFormats.firstOrNull() ?: "") }
            var muxer by remember(encoder) { mutableStateOf(muxers.firstOrNull() ?: "") }
            val frameRates = c.frameRatesList
            var frameRate by remember(c) { mutableStateOf(frameRates.firstOrNull() ?: 30.0) }

            Picker("Codec", codecs.map { it.codec }, codec) { codec = it }
            Picker("Encoder", encoders.map { it.encoder }, encoder) { encoder = it }
            Picker("Pixel format", pixelFormats, pixelFormat) { pixelFormat = it }
            Picker("Container (muxer)", muxers, muxer) { muxer = it }
            Picker("Frame rate", frameRates.map { it.toString() }, frameRate.toString()) { frameRate = it.toDoubleOrNull() ?: frameRate }

            var status by remember { mutableStateOf<String?>(null) }
            var progress by remember { mutableStateOf<Float?>(null) }
            var rendering by remember { mutableStateOf(false) }

            fun doRender() {
                val sid = app.sessions.sessionId ?: return
                if (rendering || encoder.isEmpty()) return
                (app.screen.value as? AppScreen.Sequence)?.vm?.processing?.stop() // free the shared progress slot
                rendering = true
                status = "Rendering…"
                val settings = VideoEncodeSettings.newBuilder()
                    .setFrameRate(frameRate).setCodec(codec).setEncoder(encoder)
                    .setPixelFormat(pixelFormat).setMuxer(muxer).build()
                scope.launch {
                    try {
                        app.export.exportVideo(sid, "", settings).collect { ev ->
                            if (ev.kindCase == ProgressEvent.KindCase.IO_PROGRESS) {
                                val io = ev.ioProgress
                                progress = if (io.total > 0) io.current.toFloat() / io.total else null
                                status = "Rendering ${io.current} / ${io.total}"
                            }
                        }
                        status = "Done"
                    } catch (e: Throwable) {
                        status = "Error: ${e.message}"
                    } finally {
                        rendering = false
                    }
                }
            }

            // Auto-start when opened from the render prompt's "Yes" (once codecs + a default encoder load).
            val autoStart by app.renderVideoAutoStart.collectAsState()
            LaunchedEffect(autoStart, encoder) { if (autoStart && !rendering && encoder.isNotEmpty()) doRender() }

            status?.let { Text(it, color = StarColors.textSecondary, fontSize = 12.sp) }
            if (rendering) LinearProgressIndicator(progress = { progress ?: 0f }, modifier = Modifier.fillMaxWidth(), color = StarColors.accent)

            Row(Modifier.fillMaxWidth().padding(top = 8.dp), horizontalArrangement = Arrangement.spacedBy(10.dp, Alignment.End)) {
                OutlinedButton(onClick = app::closeRenderVideo, enabled = !rendering) { Text("Cancel") }
                Button(
                    enabled = !rendering && encoder.isNotEmpty(),
                    onClick = { doRender() },
                    colors = ButtonDefaults.buttonColors(containerColor = StarColors.accent),
                ) { Text("Render") }
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
