package com.star.desktop.ui.loading

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.star.desktop.domain.LoadingProgress
import com.star.desktop.i18n.localized
import com.star.desktop.ui.theme.StarColors

/**
 * The screen shown while a source opens (macOS `ImageSequenceLoadingView`): what is being opened, a ring that fills as the video's frames are
 * extracted and then as the frames are loaded (a spinner while the video is only being examined), what it has done so far, and a Cancel that
 * really stops the open: the daemon gives up, stops ffmpeg if it was decoding, and leaves no session behind.
 */
@Composable
fun OpeningView(progress: LoadingProgress, onCancel: () -> Unit, modifier: Modifier = Modifier) {
    Box(modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(24.dp),
            modifier = Modifier.padding(32.dp),
        ) {
            Text(progress.title, color = StarColors.textPrimary, fontSize = 22.sp, maxLines = 2, overflow = TextOverflow.Ellipsis, textAlign = TextAlign.Center)
            val fraction = progress.fraction
            if (fraction != null) {
                CircularProgressIndicator(
                    progress = { fraction }, modifier = Modifier.size(160.dp), color = StarColors.accent, trackColor = StarColors.cellDefault, strokeWidth = 10.dp,
                )
            } else {
                CircularProgressIndicator(modifier = Modifier.size(64.dp), color = StarColors.accent)
            }
            // When a stage is done the next has not reported yet: say so in green, with the spinner that says more is coming.
            Text(progress.caption, color = if (progress.isComplete) StarColors.green else StarColors.textPrimary, fontSize = 15.sp)
            if (progress.isComplete) CircularProgressIndicator(modifier = Modifier.size(24.dp), color = StarColors.textSecondary, strokeWidth = 2.dp)
            OutlinedButton(onClick = onCancel) { Text(localized("ui.cancel"), fontSize = 16.sp) }
        }
    }
}
