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
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Slider
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.star.desktop.domain.FrameFormatChoice
import com.star.desktop.domain.VideoImport
import com.star.desktop.i18n.localized
import com.star.desktop.ui.theme.StarColors
import com.star.desktop.ui.theme.StarShapes
import com.star.proto.ProbeVideoResponse
import java.io.File

/**
 * Asks how the frames of a video are to be written before any of it is decoded (macOS `VideoImportSheetView`): 16 bit or 8 bit tiff, or jpeg
 * with a quality, defaulting to 16 bit tiff and jpeg at 80. Says how much disk that takes once the daemon has read the video's header, if
 * it could tell how long the video is; [probe] is that read, run once.
 */
@Composable
fun VideoImportDialog(
    videoPath: String,
    probe: suspend (String) -> ProbeVideoResponse?,
    onImport: (FrameFormatChoice, Int) -> Unit,
    onCancel: () -> Unit,
) {
    var format by remember { mutableStateOf(FrameFormatChoice.TIFF16) }
    var quality by remember { mutableFloatStateOf(VideoImport.DEFAULT_JPEG_QUALITY.toFloat()) }
    val info by produceState<ProbeVideoResponse?>(null, videoPath) { value = runCatching { probe(videoPath) }.getOrNull() }

    Box(Modifier.fillMaxSize().background(StarColors.scrim).clickable(onClick = onCancel), contentAlignment = Alignment.Center) {
        Column(
            modifier = Modifier
                .widthIn(max = 520.dp)
                .clip(StarShapes.card)
                .background(StarColors.prefsCard)
                .clickable(enabled = false) {}
                .padding(24.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text(localized("ui.video_import_title"), color = StarColors.textPrimary, fontWeight = FontWeight.SemiBold, fontSize = 18.sp)
            Text(File(videoPath).name, color = StarColors.textPrimary, fontSize = 13.sp)
            Text(localized("ui.video_import_blurb"), color = StarColors.textSecondary, fontSize = 12.sp)

            Text(localized("ui.video_frame_format"), color = StarColors.textSecondary, fontSize = 12.sp)
            FrameFormatChoice.entries.forEach { choice ->
                Row(
                    Modifier.fillMaxWidth().clip(RoundedCornerShape(4.dp)).clickable { format = choice },
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    RadioButton(selected = format == choice, onClick = { format = choice })
                    Text(localized(choice.labelKey), color = StarColors.textPrimary, fontSize = 13.sp)
                }
            }

            val q = quality.toInt()
            if (format == FrameFormatChoice.JPEG) {
                Text(localized("ui.jpeg_quality", q), color = StarColors.textPrimary, fontSize = 12.sp)
                Slider(
                    value = quality,
                    onValueChange = { quality = it },
                    valueRange = VideoImport.MIN_JPEG_QUALITY.toFloat()..VideoImport.MAX_JPEG_QUALITY.toFloat(),
                    steps = VideoImport.MAX_JPEG_QUALITY - VideoImport.MIN_JPEG_QUALITY - 1,
                    modifier = Modifier.fillMaxWidth(),
                )
            }

            // Nothing until the header has been read; then the estimate, or why there is none.
            info?.let { p ->
                val bytes = VideoImport.estimatedBytes(p, format, q)
                if (bytes != null) {
                    Text(
                        localized("ui.video_import_disk_usage", VideoImport.formatBytes(bytes), p.frameCount, p.width, p.height),
                        color = StarColors.textPrimary, fontSize = 12.sp,
                    )
                } else {
                    Text(localized("ui.video_import_disk_unknown"), color = StarColors.textSecondary, fontSize = 12.sp)
                }
            }

            Row(Modifier.fillMaxWidth().padding(top = 8.dp), horizontalArrangement = Arrangement.spacedBy(10.dp, Alignment.End)) {
                OutlinedButton(onClick = onCancel) { Text(localized("ui.cancel")) }
                Button(
                    onClick = { onImport(format, q) },
                    colors = ButtonDefaults.buttonColors(containerColor = StarColors.accent),
                ) { Text(localized("ui.video_import_start")) }
            }
        }
    }
}
