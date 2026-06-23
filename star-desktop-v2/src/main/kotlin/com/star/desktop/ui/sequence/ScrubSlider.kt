package com.star.desktop.ui.sequence

import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.star.desktop.ui.theme.StarColors
import kotlin.math.roundToInt

/** Full-width scrub slider (macOS `ScrubSliderView`), disabled during playback, synced to currentIndex. */
@Composable
fun ScrubSlider(vm: SequenceViewModel, modifier: Modifier = Modifier) {
    if (vm.frameCount <= 1) return
    val idx by vm.currentIndex.collectAsState()
    val playing by vm.isPlaying.collectAsState()
    Slider(
        value = idx.toFloat(),
        onValueChange = { vm.setCurrentIndex(it.roundToInt()) },
        valueRange = 0f..(vm.frameCount - 1).toFloat(),
        steps = (vm.frameCount - 2).coerceAtLeast(0),
        enabled = !playing,
        colors = SliderDefaults.colors(
            thumbColor = StarColors.accent,
            activeTrackColor = StarColors.accent,
            inactiveTrackColor = StarColors.pickerTrack,
        ),
        modifier = modifier.fillMaxWidth().padding(horizontal = 16.dp),
    )
}
