package com.star.desktop.ui.sequence

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.foundation.layout.padding
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.TextUnit
import com.star.desktop.domain.ViewModes
import com.star.desktop.ui.theme.StarColors
import com.star.desktop.i18n.localized
import com.star.proto.FrameViewMode

/**
 * The center frame display: shows the current frame's picture in the view mode that is showing (aspect-fit). A frame that has no picture
 * of that kind says so, as the macOS gui does (`FrameViewModel.previewImage`): it does not show another kind in its place.
 */
@Composable
fun FrameImageView(vm: SequenceViewModel, background: Color = StarColors.appBackground, modifier: Modifier = Modifier) {
    val bmp by vm.currentPreview.collectAsState()
    val available by vm.previewAvailable.collectAsState()
    val idx by vm.currentIndex.collectAsState()
    val mode by vm.viewMode.collectAsState()

    Box(modifier.fillMaxSize().background(background), contentAlignment = Alignment.Center) {
        val current = bmp
        if (current != null) {
            Image(
                bitmap = current,
                contentDescription = localized("ui.frame_n", idx),
                modifier = Modifier.fillMaxSize(),
                contentScale = ContentScale.Fit,
            )
        } else if (!available) {
            ImageNotFound(imageNotFoundText(mode), fontSize = 28.sp, modifier = Modifier.fillMaxSize())
        } else {
            Text(localized("ui.loading_frame_n", idx), color = StarColors.textSecondary, fontSize = 13.sp)
        }
    }
}

/** "[mode] image not found for this frame" (macOS: `ui.image_not_found_for_frame` with the mode's long name). */
fun imageNotFoundText(mode: FrameViewMode): String = localized("ui.image_not_found_for_frame", ViewModes.longName(mode))

/** What stands where a picture is missing: a dark cell with [text] in grey, centred (macOS `Color(white: 0.15)` and `Color(white: 0.45)`). */
@Composable
fun ImageNotFound(text: String, fontSize: TextUnit, modifier: Modifier = Modifier) {
    Box(modifier.background(Color(0.15f, 0.15f, 0.15f)), contentAlignment = Alignment.Center) {
        Text(
            text, color = Color(0.45f, 0.45f, 0.45f), fontSize = fontSize, fontWeight = FontWeight.Medium,
            textAlign = TextAlign.Center, modifier = Modifier.padding(4.dp),
        )
    }
}
