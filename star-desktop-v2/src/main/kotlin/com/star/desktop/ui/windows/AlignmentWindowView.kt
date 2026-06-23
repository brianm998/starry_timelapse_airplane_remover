package com.star.desktop.ui.windows

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.star.desktop.ui.app.AppViewModel
import com.star.desktop.ui.sequence.SequenceViewModel
import com.star.desktop.ui.theme.StarColors
import com.star.proto.AlignmentInfo
import kotlin.math.abs
import kotlin.math.roundToInt

/**
 * Alignment diagnostics window (macOS `AlignmentWindowView`): per-frame star-alignment deviation
 * (one series per neighbor offset, signed by offset) and sky-keypoint counts, with a current-frame
 * marker. Click a chart to jump to that frame. Driven by `Alignment.GetSequence`.
 */
@Composable
fun AlignmentWindowView(app: AppViewModel, svm: SequenceViewModel) {
    val seq by produceState<List<AlignmentInfo>?>(null, svm.sessionId) {
        value = runCatching { app.alignmentRepo.sequence(svm.sessionId, includeHomography = false, includePreviews = false) }
            .getOrNull()?.framesList
    }
    val current by svm.currentIndex.collectAsState()
    val count = svm.frameCount

    Column(Modifier.fillMaxSize().background(StarColors.appBackground).padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text("Alignment", color = StarColors.textPrimary, fontWeight = FontWeight.SemiBold, fontSize = 16.sp)

        val frames = seq
        if (frames == null || frames.isEmpty()) {
            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                Text("No alignment data — process the sequence first.", color = StarColors.textDisabled, fontSize = 12.sp)
            }
            return@Column
        }

        // Build per-offset deviation series: (frameIndex, signedDeviation).
        val byOffset = sortedMapOf<Int, MutableList<Pair<Int, Double>>>()
        var maxAbsDev = 1e-6
        for (f in frames) {
            if (!f.hasStarResults) continue
            for (n in f.star.neighborsList) {
                val offset = n.frameIndex - f.frameIndex
                val signed = if (offset >= 0) n.deviation else -n.deviation
                byOffset.getOrPut(offset) { mutableListOf() }.add(f.frameIndex to signed)
                maxAbsDev = maxOf(maxAbsDev, abs(n.deviation))
            }
        }

        Text("Star alignment deviation (per neighbor offset)", color = StarColors.textSecondary, fontSize = 11.sp)
        DeviationChart(byOffset, maxAbsDev, count, current) { svm.setCurrentIndex(it) }

        OffsetLegend(byOffset.keys.toList())

        Text("Sky keypoints", color = StarColors.textSecondary, fontSize = 11.sp, modifier = Modifier.padding(top = 6.dp))
        KeypointChart(frames, count, current) { svm.setCurrentIndex(it) }
    }
}

private fun offsetColor(offset: Int): Color {
    val palette = listOf(StarColors.blue, StarColors.green, StarColors.orange, StarColors.purple, StarColors.mint, StarColors.pink, StarColors.yellow, StarColors.red)
    return palette[(abs(offset)) % palette.size]
}

@Composable
private fun DeviationChart(series: Map<Int, List<Pair<Int, Double>>>, maxAbsDev: Double, count: Int, current: Int, onPick: (Int) -> Unit) {
    Canvas(
        Modifier.fillMaxWidth().height(180.dp).background(StarColors.prefsCard)
            .pointerInput(count) { detectTapGestures { pos -> onPick(pickFrame(pos.x, size.width.toFloat(), count)) } },
    ) {
        val w = size.width; val h = size.height
        fun x(frame: Int) = if (count <= 1) w / 2 else frame.toFloat() / (count - 1) * w
        fun y(dev: Double) = (h / 2f) - (dev / maxAbsDev).toFloat() * (h / 2f - 6f)
        // zero axis
        drawLine(StarColors.gray.copy(alpha = 0.5f), Offset(0f, h / 2f), Offset(w, h / 2f), 1f)
        // current-frame marker
        drawLine(StarColors.accent, Offset(x(current), 0f), Offset(x(current), h), 1.5f)
        for ((offset, points) in series) {
            val color = offsetColor(offset)
            val sorted = points.sortedBy { it.first }
            for (i in 1 until sorted.size) {
                drawLine(color, Offset(x(sorted[i - 1].first), y(sorted[i - 1].second)), Offset(x(sorted[i].first), y(sorted[i].second)), 1.5f)
            }
            for (p in sorted) drawCircle(color, 2.5f, Offset(x(p.first), y(p.second)))
        }
    }
}

@Composable
private fun KeypointChart(frames: List<AlignmentInfo>, count: Int, current: Int, onPick: (Int) -> Unit) {
    val pts = frames.filter { it.numSkyKeypoints >= 0 }.map { it.frameIndex to it.numSkyKeypoints }
    val maxKp = (pts.maxOfOrNull { it.second } ?: 1).coerceAtLeast(1)
    Canvas(
        Modifier.fillMaxWidth().height(120.dp).background(StarColors.prefsCard)
            .pointerInput(count) { detectTapGestures { pos -> onPick(pickFrame(pos.x, size.width.toFloat(), count)) } },
    ) {
        val w = size.width; val h = size.height
        fun x(frame: Int) = if (count <= 1) w / 2 else frame.toFloat() / (count - 1) * w
        fun y(kp: Int) = h - (kp.toFloat() / maxKp) * (h - 6f)
        drawLine(StarColors.accent, Offset(x(current), 0f), Offset(x(current), h), 1.5f)
        val sorted = pts.sortedBy { it.first }
        for (i in 1 until sorted.size) {
            drawLine(StarColors.green, Offset(x(sorted[i - 1].first), y(sorted[i - 1].second)), Offset(x(sorted[i].first), y(sorted[i].second)), 1.5f)
        }
        for (p in sorted) drawCircle(StarColors.green, 2.5f, Offset(x(p.first), y(p.second)))
    }
}

@Composable
private fun OffsetLegend(offsets: List<Int>) {
    LazyRow(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        items(offsets) { off ->
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(3.dp)) {
                Box(Modifier.size(8.dp).background(offsetColor(off)))
                Text(if (off >= 0) "+$off" else "$off", color = StarColors.textSecondary, fontSize = 10.sp)
            }
        }
    }
}

private fun pickFrame(x: Float, width: Float, count: Int): Int =
    if (count <= 1 || width <= 0f) 0 else (x / width * (count - 1)).roundToInt().coerceIn(0, count - 1)
