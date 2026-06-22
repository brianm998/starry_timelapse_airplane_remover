package com.star.ui

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.*
import androidx.compose.ui.unit.*
import com.star.proto.*
import com.star.viewmodel.SequenceViewModel
import kotlinx.coroutines.launch

/**
 * Render Video dialog — mirrors RenderVideoSheetView.swift.
 *
 * Fetches VideoCapabilities from stard (Export.GetVideoCapabilities) to populate the
 * cascading pickers: frame rate → codec → encoder → pixel format → muxer.
 * Matching the Swift RenderVideoSheetView: the five VideoEncodeSettings fields are shown
 * as cascading pickers driven by the VideoCapabilities graph from stard.
 */
@Composable
fun RenderVideoDialog(
    sequenceViewModel: SequenceViewModel,
    onDismiss: () -> Unit,
) {
    val scope = rememberCoroutineScope()
    val config by sequenceViewModel.config.collectAsState()

    // Load video capabilities once.
    var capabilities by remember { mutableStateOf<VideoCapabilities?>(null) }
    var capError by remember { mutableStateOf<String?>(null) }

    LaunchedEffect(Unit) {
        scope.launch {
            try {
                capabilities = sequenceViewModel.exportRepo.getVideoCapabilities()
            } catch (e: Exception) {
                capError = e.message
            }
        }
    }

    // Draft settings — defaults from config.video
    var frameRate by remember(config) { mutableStateOf(config.video.frameRate.takeIf { it > 0 } ?: 24.0) }
    var codec by remember(config) { mutableStateOf(config.video.codec) }
    var encoder by remember(config) { mutableStateOf(config.video.encoder) }
    var pixelFormat by remember(config) { mutableStateOf(config.video.pixelFormat) }
    var muxer by remember(config) { mutableStateOf(config.video.muxer) }
    var outputPath by remember { mutableStateOf("") }

    var isExporting by remember { mutableStateOf(false) }
    var exportProgress by remember { mutableStateOf<String?>(null) }
    var exportError by remember { mutableStateOf<String?>(null) }

    AlertDialog(
        onDismissRequest = { if (!isExporting) onDismiss() },
        title = { Text("Render Video") },
        text = {
            Column(
                Modifier.verticalScroll(rememberScrollState()).width(520.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                if (capError != null) {
                    Text("Could not load video capabilities: $capError", color = MaterialTheme.colorScheme.error)
                }

                // Output path
                OutlinedTextField(
                    value = outputPath,
                    onValueChange = { outputPath = it },
                    label = { Text("Output path (leave blank for auto)") },
                    modifier = Modifier.fillMaxWidth(),
                    singleLine = true,
                )

                val caps = capabilities

                // Frame rate picker
                Text("Frame Rate", style = MaterialTheme.typography.labelMedium)
                val frameRates: List<Double> = caps?.frameRatesList?.takeIf { it.isNotEmpty() } ?: listOf(24.0, 29.97, 30.0, 60.0)
                Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                    frameRates.forEach { fr ->
                        FilterChip(
                            selected = frameRate == fr,
                            onClick = { frameRate = fr },
                            label = { Text("${fr}fps", fontSize = 11.sp) },
                        )
                    }
                }

                // Codec picker (cascading from capabilities)
                if (caps != null) {
                    Text("Codec", style = MaterialTheme.typography.labelMedium)
                    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                        caps.codecsList.forEach { codecCaps ->
                            FilterChip(
                                selected = codec == codecCaps.codec,
                                onClick = {
                                    codec = codecCaps.codec
                                    // Reset downstream selections when codec changes
                                    encoder = codecCaps.encodersList.firstOrNull()?.encoder ?: ""
                                    pixelFormat = codecCaps.encodersList.firstOrNull()?.pixelFormatsList?.firstOrNull() ?: ""
                                    muxer = codecCaps.encodersList.firstOrNull()?.muxersList?.firstOrNull() ?: ""
                                },
                                label = { Text(codecCaps.codec, fontSize = 11.sp) },
                            )
                        }
                    }

                    // Encoder picker (depends on codec)
                    val selectedCodecCaps = caps.codecsList.firstOrNull { it.codec == codec }
                    if (selectedCodecCaps != null) {
                        Text("Encoder", style = MaterialTheme.typography.labelMedium)
                        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                            selectedCodecCaps.encodersList.forEach { encCaps ->
                                FilterChip(
                                    selected = encoder == encCaps.encoder,
                                    onClick = {
                                        encoder = encCaps.encoder
                                        pixelFormat = encCaps.pixelFormatsList.firstOrNull() ?: ""
                                        muxer = encCaps.muxersList.firstOrNull() ?: ""
                                    },
                                    label = { Text(encCaps.encoder.take(20), fontSize = 10.sp) },
                                )
                            }
                        }

                        // Pixel format picker
                        val selectedEncoderCaps = selectedCodecCaps.encodersList.firstOrNull { it.encoder == encoder }
                        if (selectedEncoderCaps != null && selectedEncoderCaps.pixelFormatsList.isNotEmpty()) {
                            Text("Pixel Format", style = MaterialTheme.typography.labelMedium)
                            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                                selectedEncoderCaps.pixelFormatsList.forEach { pf ->
                                    FilterChip(
                                        selected = pixelFormat == pf,
                                        onClick = { pixelFormat = pf },
                                        label = { Text(pf.take(16), fontSize = 10.sp) },
                                    )
                                }
                            }

                            // Muxer picker
                            if (selectedEncoderCaps.muxersList.isNotEmpty()) {
                                Text("Container / Muxer", style = MaterialTheme.typography.labelMedium)
                                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                                    selectedEncoderCaps.muxersList.forEach { m ->
                                        FilterChip(
                                            selected = muxer == m,
                                            onClick = { muxer = m },
                                            label = { Text(m, fontSize = 11.sp) },
                                        )
                                    }
                                }
                            }
                        }
                    }
                } else if (capError == null) {
                    CircularProgressIndicator(Modifier.size(24.dp))
                }

                // Export progress / error
                exportProgress?.let { Text(it, color = MaterialTheme.colorScheme.primary, fontSize = 12.sp) }
                exportError?.let { Text("Error: $it", color = MaterialTheme.colorScheme.error, fontSize = 12.sp) }
            }
        },
        confirmButton = {
            TextButton(
                enabled = !isExporting,
                onClick = {
                    val settings = VideoEncodeSettings.newBuilder()
                        .setFrameRate(frameRate)
                        .setCodec(codec)
                        .setEncoder(encoder)
                        .setPixelFormat(pixelFormat)
                        .setMuxer(muxer)
                        .build()
                    isExporting = true
                    exportProgress = "Starting export…"
                    sequenceViewModel.exportVideo(
                        outputPath = outputPath,
                        settings = settings,
                        onProgress = { event ->
                            if (event.hasIoProgress()) {
                                val io = event.ioProgress
                                exportProgress = "Encoding: ${io.current} / ${io.total}"
                            }
                        },
                        onComplete = {
                            isExporting = false
                            exportProgress = "Export complete!"
                            onDismiss()
                        },
                        onError = { msg ->
                            isExporting = false
                            exportError = msg
                        },
                    )
                },
            ) {
                Text(if (isExporting) "Exporting…" else "Export")
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss, enabled = !isExporting) { Text("Cancel") }
        },
    )
}
