package com.star.desktop.ui.sequence

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.star.desktop.domain.ExtractionFormat
import com.star.desktop.i18n.localized
import com.star.desktop.ui.theme.StarColors
import com.star.proto.FrameEtaResponse
import kotlinx.coroutines.delay

/**
 * The band along the scrub slider showing which frames are extracted, as a video player shows what is buffered: where the user can go without
 * waiting. Drawn only while a video is still being extracted.
 */
@Composable
fun ExtractedRangesBand(vm: SequenceViewModel, modifier: Modifier = Modifier) {
    val extracted by vm.extractedFrames.collectAsState()
    val frames = extracted ?: return
    val total = vm.frameCount.coerceAtLeast(1)
    Canvas(modifier.fillMaxWidth().height(4.dp).clip(RoundedCornerShape(2.dp)).testTag("extraction.band")) {
        drawRect(StarColors.gray.copy(alpha = 0.35f))
        for (r in frames.ranges) {
            val x0 = size.width * r.first / total
            val x1 = size.width * (r.last + 1) / total
            drawRect(StarColors.green.copy(alpha = 0.8f), topLeft = Offset(x0, 0f), size = Size(maxOf(1f, x1 - x0), size.height))
        }
    }
}

/**
 * A compact strip while a video is being extracted: a bar and "Extracting video: 1,234 of 5,000 frames (about 4 min left)". Gone once it is
 * done; an error that does not go away on its own if it failed.
 */
@Composable
fun ExtractionStrip(vm: SequenceViewModel, modifier: Modifier = Modifier) {
    val extraction by vm.extraction.collectAsState()
    val extracting by vm.isExtracting.collectAsState()
    val e = extraction ?: return
    if (e.error.isNotEmpty()) {
        Text(localized("ui.extraction_failed", e.error), color = StarColors.red, fontSize = 12.sp,
            modifier = modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 2.dp).testTag("extraction.error"))
        return
    }
    if (!extracting) return
    Row(
        modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 2.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        LinearProgressIndicator(
            progress = { if (e.total > 0) e.extracted.toFloat() / e.total else 0f },
            modifier = Modifier.width(240.dp).testTag("extraction.progress"),
            color = StarColors.accent,
        )
        var text = localized("ui.extracting_video_progress", "%,d".format(e.extracted), "%,d".format(e.total))
        if (e.etaKnown) text += " (" + localized("ui.extracting_video_eta", ExtractionFormat.duration(e.etaSeconds)) + ")"
        Text(text, color = StarColors.textPrimary, fontSize = 12.sp)
    }
}

/**
 * What the main frame area shows over a frame that is not extracted yet: how long it will probably be, with a progress indicator. The tools that
 * need the original cannot be used on it (the panel takes the pointer), and it goes when the frame lands. Asked of the engine about once a second.
 */
@Composable
fun FrameWaitPanel(vm: SequenceViewModel, modifier: Modifier = Modifier) {
    val index by vm.currentIndex.collectAsState()
    var eta by remember(index) { mutableStateOf<FrameEtaResponse?>(null) }
    LaunchedEffect(index) {
        while (true) {
            eta = vm.frameEta(index)
            delay(1000)
        }
    }
    Box(
        modifier.fillMaxSize().background(StarColors.appBackground.copy(alpha = 0.85f))
            // nothing underneath can be clicked or dragged while the frame is not there
            .pointerInput(Unit) {
                awaitPointerEventScope {
                    while (true) {
                        val event = awaitPointerEvent(PointerEventPass.Initial)
                        event.changes.forEach { it.consume() }
                    }
                }
            }
            .testTag("extraction.waitpanel"),
        contentAlignment = Alignment.Center,
    ) {
        Column(
            Modifier.clip(RoundedCornerShape(10.dp)).background(Color.Black.copy(alpha = 0.7f)).padding(24.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Text(localized("ui.frame_not_extracted", "%,d".format(index)), color = StarColors.white, fontSize = 18.sp)
            val e = eta
            val seekable = vm.extraction.collectAsState().value?.seekable ?: true
            val now = e?.jump == true || seekable
            if (e != null && e.known) {
                if (now) {
                    Text(localized("ui.frame_extracting_now", ExtractionFormat.duration(e.seconds)), color = StarColors.white, fontSize = 13.sp)
                    LinearProgressIndicator(Modifier.width(260.dp), color = StarColors.accent)
                } else {
                    Text(
                        localized("ui.frame_extraction_in_order", "%,d".format(e.sweepHead), ExtractionFormat.duration(e.seconds)),
                        color = StarColors.white, fontSize = 13.sp,
                    )
                    LinearProgressIndicator(progress = { e.fraction.toFloat().coerceIn(0f, 1f) }, modifier = Modifier.width(260.dp), color = StarColors.accent)
                }
            } else {
                Text(localized("ui.frame_extraction_estimating"), color = StarColors.white, fontSize = 13.sp)
                LinearProgressIndicator(Modifier.width(260.dp), color = StarColors.accent)
            }
            if (!now) Text(localized("ui.frame_extraction_in_order_reason"), color = StarColors.textSecondary, fontSize = 11.sp)
            if (e != null && e.error.isNotEmpty()) Text(localized("ui.extraction_failed", e.error), color = StarColors.red, fontSize = 12.sp)
        }
    }
}
