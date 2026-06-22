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

/**
 * Processing settings dialog — mirrors ProcessingSettingsView.swift.
 * All settings map to Config fields via Sequence.UpdateConfig.
 */
@Composable
fun ProcessingSettingsDialog(
    sequenceViewModel: SequenceViewModel,
    onDismiss: () -> Unit,
) {
    val config by sequenceViewModel.config.collectAsState()
    var draft by remember(config) { mutableStateOf(config) }

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Processing Settings") },
        text = {
            Column(
                Modifier.verticalScroll(rememberScrollState()).width(480.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                // Detection type
                Text("Detection Type", style = MaterialTheme.typography.labelMedium)
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    listOf(DetectionType.DETECTION_MILD, DetectionType.DETECTION_STRONG, DetectionType.DETECTION_STRONGER, DetectionType.DETECTION_EXCESSIVE, DetectionType.DETECTION_CUSTOM).forEach { dt ->
                        FilterChip(
                            selected = draft.detectionType == dt,
                            onClick = { draft = draft.toBuilder().setDetectionType(dt).build() },
                            label = { Text(dt.name.removePrefix("DETECTION_").lowercase().replaceFirstChar { it.uppercase() }, fontSize = 11.sp) },
                        )
                    }
                }

                // Horizon detection
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    Text("Horizon Detection", Modifier.weight(1f))
                    Switch(
                        checked = draft.horizonDetectionEnabled,
                        onCheckedChange = { draft = draft.toBuilder().setHorizonDetectionEnabled(it).build() },
                    )
                }

                // Tripod head moving
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    Text("Tripod Head Was Moving", Modifier.weight(1f))
                    Switch(
                        checked = draft.tripodHeadWasMoving,
                        onCheckedChange = { draft = draft.toBuilder().setTripodHeadWasMoving(it).build() },
                    )
                }

                // Concurrent frames
                Text("Frames Processed Concurrently: ${draft.numberOfFramesToProcessConcurrently}", style = MaterialTheme.typography.labelMedium)
                Slider(
                    value = draft.numberOfFramesToProcessConcurrently.toFloat(),
                    onValueChange = { draft = draft.toBuilder().setNumberOfFramesToProcessConcurrently(it.toInt()).build() },
                    valueRange = 1f..16f,
                    steps = 14,
                )

                // Write outlier group files
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    Text("Write Outlier Group Files", Modifier.weight(1f))
                    Switch(
                        checked = draft.writeOutlierGroupFiles,
                        onCheckedChange = { draft = draft.toBuilder().setWriteOutlierGroupFiles(it).build() },
                    )
                }

                // Write frame preview files
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    Text("Write Frame Preview Files", Modifier.weight(1f))
                    Switch(
                        checked = draft.writeFramePreviewFiles,
                        onCheckedChange = { draft = draft.toBuilder().setWriteFramePreviewFiles(it).build() },
                    )
                }

                // Clean method default
                Text("Default Clean Method", style = MaterialTheme.typography.labelMedium)
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    listOf(CleanMethod.CLEAN_AUTOMATIC, CleanMethod.CLEAN_AUTOMATIC_TRUE, CleanMethod.CLEAN_SELECTIVE).forEach { cm ->
                        FilterChip(
                            selected = draft.cleanMethod == cm,
                            onClick = { draft = draft.toBuilder().setCleanMethod(cm).build() },
                            label = {
                                Text(
                                    when (cm) {
                                        CleanMethod.CLEAN_AUTOMATIC -> "Auto"
                                        CleanMethod.CLEAN_AUTOMATIC_TRUE -> "Auto Force"
                                        CleanMethod.CLEAN_SELECTIVE -> "Selective"
                                        else -> cm.name
                                    },
                                    fontSize = 11.sp,
                                )
                            },
                        )
                    }
                }
            }
        },
        confirmButton = {
            TextButton(onClick = {
                sequenceViewModel.updateConfig(draft)
                onDismiss()
            }) { Text("Apply") }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) { Text("Cancel") }
        },
    )
}
