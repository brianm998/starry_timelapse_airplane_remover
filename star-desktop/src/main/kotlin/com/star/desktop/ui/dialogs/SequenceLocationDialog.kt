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
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.star.desktop.domain.WorkingLocation
import com.star.desktop.i18n.localized
import com.star.desktop.ui.theme.StarColors
import com.star.desktop.ui.theme.StarShapes
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File

/**
 * Asked before an image sequence is opened (the counterpart of [VideoImportDialog], which has this in it for a video): where its output and
 * working files go, with what they will take, sized from the images in the folder, and what the volume has free. [onOpen] gets the folder the
 * user chose, or null for beside the sequence.
 */
@Composable
fun SequenceLocationDialog(
    sequenceDir: String,
    onOpen: (outputDir: String?) -> Unit,
    onCancel: () -> Unit,
) {
    var outputDir by remember { mutableStateOf<String?>(null) }
    // Stat-ing thousands of images is not for the UI thread.
    val inputBytes by produceState<Long?>(null, sequenceDir) { value = withContext(Dispatchers.IO) { WorkingLocation.sequenceInputBytes(File(sequenceDir)) } }

    Box(Modifier.fillMaxSize().background(StarColors.scrim).clickable(onClick = onCancel), contentAlignment = Alignment.Center) {
        Column(
            modifier = Modifier
                .widthIn(max = 520.dp)
                .clip(StarShapes.card)
                .background(StarColors.prefsCard)
                .clickable(enabled = false) {}
                .verticalScroll(rememberScrollState())
                .padding(24.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text(localized("ui.sequence_location_title"), color = StarColors.textPrimary, fontWeight = FontWeight.SemiBold, fontSize = 18.sp)
            Text(File(sequenceDir).name, color = StarColors.textPrimary, fontSize = 13.sp)
            WorkingLocationSection(sequenceDir, outputDir, { outputDir = it }, inputBytes = inputBytes)
            Row(Modifier.fillMaxWidth().padding(top = 8.dp), horizontalArrangement = Arrangement.spacedBy(10.dp, Alignment.End)) {
                OutlinedButton(onClick = onCancel) { Text(localized("ui.cancel")) }
                Button(
                    onClick = { onOpen(outputDir) },
                    colors = ButtonDefaults.buttonColors(containerColor = StarColors.accent),
                    modifier = Modifier.testTag("sequencelocation.open"),
                ) { Text(localized("ui.sequence_location_open")) }
            }
        }
    }
}
