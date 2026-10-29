package com.star.desktop.ui.dialogs

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.star.desktop.domain.VideoImport
import com.star.desktop.domain.WorkingLocation
import com.star.desktop.i18n.localized
import com.star.desktop.ui.initial.chooseDirectory
import com.star.desktop.ui.theme.StarColors
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

private const val UNKNOWN_FREE = -1L

/**
 * Where the output, the working files and (for a video) the extracted frames go, with what that will take and what the volume has free, so the
 * user can see whether it fits before agreeing. [folder] null is beside the [source].
 *
 * [inputBytes] is what the run is sized by: the sequence's own images, or the frames the video will be extracted to. The extraction itself is
 * [frameBytes] (video only), which lands on the same volume and so counts toward what is needed. Either null is "not known", and no total is shown.
 */
@Composable
fun WorkingLocationSection(
    source: String,
    folder: String?,
    onFolder: (String?) -> Unit,
    inputBytes: Long?,
    frameBytes: Long? = null,
) {
    val effective = folder ?: WorkingLocation.defaultFolder(source)
    // null while it is being read, UNKNOWN_FREE when the volume would not say.
    val freeOrUnknown by produceState<Long?>(null, effective) { value = withContext(Dispatchers.IO) { WorkingLocation.freeBytes(effective) ?: UNKNOWN_FREE } }
    val free = freeOrUnknown?.takeIf { it != UNKNOWN_FREE }
    val processing = inputBytes?.let(WorkingLocation::runBytes)
    val total = processing?.let { it + (frameBytes ?: 0L) }
    val short = if (total != null) free?.let { total - it }?.takeIf { it > 0 } else null

    Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Text(localized("ui.location_title"), color = StarColors.textSecondary, fontSize = 12.sp)
        Text(localized("ui.location_blurb"), color = StarColors.textSecondary, fontSize = 11.sp)
        Text(effective, color = StarColors.textPrimary, fontSize = 12.sp, modifier = Modifier.testTag("location.folder"))
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
            OutlinedButton(
                onClick = { chooseDirectory(localized("ui.location_title"), effective)?.let(onFolder) },
                modifier = Modifier.testTag("location.choose"),
            ) { Text(localized("ui.location_choose")) }
            if (folder != null) OutlinedButton(onClick = { onFolder(null) }, modifier = Modifier.testTag("location.reset")) { Text(localized("ui.location_beside")) }
        }
        if (total != null) {
            val needed = if (frameBytes != null) {
                localized("ui.location_needed_video", VideoImport.formatBytes(total), VideoImport.formatBytes(frameBytes), VideoImport.formatBytes(processing))
            } else {
                localized("ui.location_needed", VideoImport.formatBytes(total))
            }
            Text(needed, color = StarColors.textPrimary, fontSize = 12.sp, modifier = Modifier.testTag("location.needed"))
        }
        if (freeOrUnknown == UNKNOWN_FREE) {
            Text(localized("ui.location_unknown_free"), color = StarColors.textSecondary, fontSize = 12.sp)
        } else {
            free?.let { Text(localized("ui.location_available", VideoImport.formatBytes(it)), color = StarColors.textPrimary, fontSize = 12.sp, modifier = Modifier.testTag("location.available")) }
        }
        if (short != null) {
            Text(localized("ui.location_short", VideoImport.formatBytes(short)), color = StarColors.red, fontSize = 12.sp, modifier = Modifier.testTag("location.short"))
        }
    }
}
