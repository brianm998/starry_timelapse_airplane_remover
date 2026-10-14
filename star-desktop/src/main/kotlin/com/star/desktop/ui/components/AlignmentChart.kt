package com.star.desktop.ui.components

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.clipRect
import androidx.compose.ui.graphics.drawscope.rotate
import androidx.compose.ui.input.pointer.PointerEventType
import androidx.compose.ui.input.pointer.isCtrlPressed
import androidx.compose.ui.input.pointer.isMetaPressed
import androidx.compose.ui.input.pointer.onPointerEvent
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.TextMeasurer
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.drawText
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.star.desktop.domain.AlignmentCharts
import com.star.desktop.domain.ChartTicks
import com.star.desktop.domain.DeviationPoint
import com.star.desktop.domain.XDomain
import com.star.desktop.i18n.localized
import com.star.desktop.ui.theme.StarColors
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.pow
import kotlin.math.roundToInt

/**
 * The charts of the alignment diagnostics (macOS `AlignmentDeviationChart`, `AlignmentKeypointsChart`), drawn by the Alignment window and
 * by the left panel and processing screen (see [AlignmentCharts] for the data's side). Each takes the sequence's frame count, the current
 * frame (a red line, with the chart following it when it leaves the picture) and what to do with a click on a frame.
 *
 * Wheel zooms about the pointer (never fewer than 20 frames across), dragging pans, hovering names the reading under the pointer, clicking
 * a frame goes to it.
 */

private const val NO_FRAME = -1

/** Room around the plot for the axes' numbers and titles; the small version, for a chart in a narrow panel, has no titles and less of everything. */
private class Margins(val left: androidx.compose.ui.unit.Dp, val bottom: androidx.compose.ui.unit.Dp, val top: androidx.compose.ui.unit.Dp, val right: androidx.compose.ui.unit.Dp)

private val FULL_MARGINS = Margins(54.dp, 38.dp, 18.dp, 10.dp)
private val COMPACT_MARGINS = Margins(30.dp, 18.dp, 14.dp, 6.dp)

private val PALETTE = listOf(
    Color(0.0f, 0.478f, 1.0f),       // blue
    Color(0.204f, 0.780f, 0.349f),   // green
    Color(1.0f, 0.584f, 0.0f),       // orange
    Color(0.686f, 0.322f, 0.871f),   // purple
    Color(1.0f, 0.176f, 0.333f),     // pink
    Color(0.188f, 0.690f, 0.780f),   // teal
    Color(0.345f, 0.337f, 0.839f),   // indigo
    Color(0.635f, 0.518f, 0.369f),   // brown
)

/** The colour of the neighbor [offset] frames away; the legend and the lines both take it from here, so they cannot disagree. */
fun offsetColor(offset: Int): Color = PALETTE[AlignmentCharts.paletteIndex(offset)]

/** What hovering shows: where the mark goes, and the lines the tooltip says. */
private class Hover(val frame: Int, val value: Double, val lines: List<Pair<String, Color?>>)

/**
 * Per-offset deviation of one alignment (star or earth), with the "Height" slider that sets the fixed range either side of zero: the chart
 * does not fit the data, so one wild reading cannot flatten the rest. A warp the heuristics distrust is a red dot on its line.
 */
@Composable
fun DeviationChart(
    points: List<DeviationPoint>,
    frameCount: Int,
    current: Int,
    onPick: (Int) -> Unit,
    modifier: Modifier = Modifier,
    chartHeight: androidx.compose.ui.unit.Dp = 240.dp,
    compact: Boolean = false,
) {
    var height by remember { mutableStateOf(AlignmentCharts.DEFAULT_HEIGHT.toFloat()) }
    val series = remember(points) { AlignmentCharts.byOffset(points) }
    val byFrame = remember(points) { points.groupBy { it.frame } }

    Column(modifier, verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(localized("ui.height_2"), color = StarColors.textSecondary, fontSize = 11.sp)
            Slider(
                value = height, onValueChange = { height = it },
                valueRange = AlignmentCharts.MIN_HEIGHT.toFloat()..AlignmentCharts.MAX_HEIGHT.toFloat(),
                modifier = (if (compact) Modifier.weight(1f) else Modifier.width(240.dp)).height(24.dp),
                colors = SliderDefaults.colors(thumbColor = StarColors.accent, activeTrackColor = StarColors.accent, inactiveTrackColor = StarColors.cellDefault),
            )
        }
        TimelineChart(
            frameCount = frameCount, current = current, onPick = onPick,
            yRange = { -height.toDouble()..height.toDouble() },
            xTitle = localized("ui.frame_index"), yTitle = localized("ui.deviation"), compact = compact,
            modifier = Modifier.fillMaxWidth().height(chartHeight),
            drawSeries = { domain, x, y ->
                for ((offset, pts) in series) {
                    val path = Path()
                    var started = false
                    for (p in visible(pts, domain)) {
                        if (!started) { path.moveTo(x(p.frame), y(p.deviation)); started = true } else path.lineTo(x(p.frame), y(p.deviation))
                    }
                    drawPath(path, offsetColor(offset), style = Stroke(width = 1.5f))
                }
                // The distrusted warps, as marks of their own: a line's colour cannot vary along it.
                for ((_, pts) in series) for (p in visible(pts, domain)) if (!p.isGood) drawCircle(StarColors.red, 3.5f, Offset(x(p.frame), y(p.deviation)))
            },
            hover = { frame, value ->
                val atFrame = byFrame[frame] ?: return@TimelineChart null
                val nearest = atFrame.minByOrNull { abs(it.deviation - value) } ?: return@TimelineChart null
                Hover(
                    frame, nearest.deviation,
                    listOf(
                        localized("ui.frame_n", frame) to null,
                        localized("ui.neighbor_offset_value", if (nearest.offset > 0) "+" else "", nearest.offset) to null,
                        localized("ui.deviation_value", String.format(java.util.Locale.ROOT, "%.3f", nearest.deviation)) to
                            (if (nearest.isGood) StarColors.green else StarColors.red),
                        localized("ui.aligned_state", nearest.stateLabel) to null,
                    ),
                )
            },
        )
    }
}

/** How many keypoints each frame had, as one line. [counts] is by frame; null where it is not known. */
@Composable
fun KeypointChart(
    counts: List<Int?>,
    frameCount: Int,
    current: Int,
    onPick: (Int) -> Unit,
    modifier: Modifier = Modifier,
    chartHeight: androidx.compose.ui.unit.Dp = 200.dp,
    compact: Boolean = false,
) {
    val known = remember(counts) { counts.withIndex().filter { it.value != null }.map { it.index to it.value!! } }
    TimelineChart(
        frameCount = frameCount, current = current, onPick = onPick,
        yRange = {
            // Fitted to what is showing: from nothing up to the most any visible frame has, so zooming in on a quiet stretch shows its detail.
            0.0..max(1.0, (known.maxOfOrNull { it.second } ?: 1).toDouble() * 1.05)
        },
        xTitle = localized("ui.frame_index"), yTitle = localized("ui.number_of_key_points"), compact = compact,
        modifier = modifier.fillMaxWidth().height(chartHeight),
        drawSeries = { domain, x, y ->
            val path = Path()
            var started = false
            for ((frame, count) in known) {
                if (frame < domain.lower - 1 || frame > domain.upper + 1) continue
                if (!started) { path.moveTo(x(frame), y(count.toDouble())); started = true } else path.lineTo(x(frame), y(count.toDouble()))
            }
            drawPath(path, StarColors.blue, style = Stroke(width = 1.5f))
        },
        hover = { frame, _ ->
            val count = counts.getOrNull(frame) ?: return@TimelineChart null
            Hover(frame, count.toDouble(), listOf(localized("ui.frame_n", frame) to null, localized("ui.keypoints_n", count) to null))
        },
    )
}

/** The readings of [pts] (in frame order) that fall in [domain], and one either side so lines reach the edge of the plot. */
private fun visible(pts: List<DeviationPoint>, domain: XDomain): List<DeviationPoint> {
    var lo = pts.binarySearchBy(domain.lower) { it.frame }.let { if (it >= 0) it else -it - 1 }
    var hi = pts.binarySearchBy(domain.upper) { it.frame }.let { if (it >= 0) it else -it - 1 }
    lo = (lo - 1).coerceAtLeast(0)
    hi = (hi + 1).coerceAtMost(pts.size)
    return if (lo < hi) pts.subList(lo, hi) else emptyList()
}

@OptIn(ExperimentalComposeUiApi::class)
@Composable
private fun TimelineChart(
    frameCount: Int,
    current: Int,
    onPick: (Int) -> Unit,
    yRange: () -> ClosedFloatingPointRange<Double>,
    xTitle: String,
    yTitle: String,
    compact: Boolean,
    modifier: Modifier,
    drawSeries: DrawScope.(domain: XDomain, x: (Int) -> Float, y: (Double) -> Float) -> Unit,
    hover: (frame: Int, value: Double) -> Hover?,
) {
    var domain by remember(frameCount) { mutableStateOf(XDomain.full(frameCount)) }
    LaunchedEffect(current, frameCount) { domain = domain.ensuring(current, frameCount) }

    var size by remember { mutableStateOf(androidx.compose.ui.unit.IntSize.Zero) }
    var pointer by remember { mutableStateOf<Offset?>(null) }
    val density = LocalDensity.current
    val margins = if (compact) COMPACT_MARGINS else FULL_MARGINS
    val left = with(density) { margins.left.toPx() }
    val right = with(density) { margins.right.toPx() }
    val top = with(density) { margins.top.toPx() }
    val bottom = with(density) { margins.bottom.toPx() }
    val plot = Rect(left, top, max(left + 1f, size.width - right), max(top + 1f, size.height - bottom))
    val measurer = rememberTextMeasurer()

    val range = yRange()
    fun xOf(frame: Int): Float = plot.left + (frame - domain.lower).toFloat() / max(domain.span, 1) * plot.width
    fun yOf(value: Double): Float = plot.bottom - ((value - range.start) / (range.endInclusive - range.start)).toFloat() * plot.height
    fun valueAt(py: Float): Double = range.start + ((plot.bottom - py) / plot.height) * (range.endInclusive - range.start)
    fun frameAt(px: Float): Int = AlignmentCharts.frameAt(px - plot.left, plot.width, domain)

    val hovering = pointer?.takeIf { plot.contains(it) }?.let { p -> hover(frameAt(p.x), valueAt(p.y)) }

    Box(
        modifier
            .background(StarColors.prefsCard)
            .onSizeChanged { size = it }
            .onPointerEvent(PointerEventType.Move) { pointer = it.changes.first().position }
            .onPointerEvent(PointerEventType.Exit) { pointer = null }
            .onPointerEvent(PointerEventType.Scroll) { event ->
                val change = event.changes.first()
                val modifiers = event.keyboardModifiers
                when {
                    // Zoomed about the frame under the pointer, with Ctrl (⌘ on a Mac) held: the plain wheel is for scrolling the page the charts are
                    // on, which a chart that took every turn of it would stop at.
                    modifiers.isCtrlPressed || modifiers.isMetaPressed -> {
                        val factor = 1.12.pow((-change.scrollDelta.y).toDouble())
                        domain = domain.zoomed(factor, frameCount, anchor = frameAt(change.position.x).toDouble())
                        change.consume()
                    }
                    // A sideways scroll (a trackpad swipe, Shift and the wheel) moves along the frames, a twentieth of the picture a notch.
                    abs(change.scrollDelta.x) > 0f -> {
                        val step = (change.scrollDelta.x * domain.span * 0.05f).let { if (abs(it) < 1f) Math.signum(it) else it }
                        domain = domain.panned(step.roundToInt(), frameCount)
                        change.consume()
                    }
                }
            }
            .pointerInput(frameCount, plot.left, plot.width) { detectTapGestures { pos -> if (pos.x >= plot.left) onPick(frameAt(pos.x)) } }
            .pointerInput(frameCount, plot.width) {
                var carried = 0f
                detectDragGestures(onDragEnd = { carried = 0f }, onDragCancel = { carried = 0f }) { change, drag ->
                    change.consume()
                    // Dragging moves the picture with the pointer: the frames it passes over, a whole number at a time.
                    carried -= drag.x / plot.width * domain.span
                    val whole = carried.toInt()
                    if (whole != 0) {
                        carried -= whole
                        domain = domain.panned(whole, frameCount)
                    }
                }
            },
    ) {
        Canvas(Modifier.matchParentSize()) {
            drawAxes(measurer, plot, domain, range, xTitle, yTitle, compact)
            clipRect(plot.left, plot.top - 1f, plot.right, plot.bottom + 1f) {
                drawSeries(domain, ::xOf, ::yOf)
                if (current in domain) {
                    drawLine(StarColors.red, Offset(xOf(current), plot.top), Offset(xOf(current), plot.bottom), 2f)
                }
                hovering?.let {
                    drawLine(Color.Gray.copy(alpha = 0.4f), Offset(xOf(it.frame), plot.top), Offset(xOf(it.frame), plot.bottom), 1f)
                    drawCircle(Color.White, 5f, Offset(xOf(it.frame), yOf(it.value)))
                }
            }
            if (current in domain) {
                drawText(measurer, localized("ui.current"), Offset(xOf(current) + 4f, 1f), TextStyle(color = StarColors.red, fontSize = if (compact) 9.sp else 11.sp))
            }
        }
        hovering?.let { Tooltip(it, Offset(xOf(it.frame), yOf(it.value)), size) }
    }
}

private fun DrawScope.drawAxes(
    measurer: TextMeasurer, plot: Rect, domain: XDomain, range: ClosedFloatingPointRange<Double>, xTitle: String, yTitle: String, compact: Boolean,
) {
    val label = TextStyle(color = StarColors.textSecondary, fontSize = if (compact) 9.sp else 10.sp)
    val grid = StarColors.gray.copy(alpha = 0.25f)

    for (v in ChartTicks.nice(range.start, range.endInclusive, if (compact) 3 else 5)) {
        val y = plot.bottom - ((v - range.start) / (range.endInclusive - range.start)).toFloat() * plot.height
        drawLine(grid, Offset(plot.left, y), Offset(plot.right, y), 1f)
        val text = measurer.measure(ChartTicks.label(v), label)
        drawText(text, topLeft = Offset(plot.left - text.size.width - 6f, y - text.size.height / 2f))
    }
    for (f in ChartTicks.nice(domain.lower.toDouble(), domain.upper.toDouble(), if (compact) 3 else 6)) {
        val x = plot.left + ((f - domain.lower) / max(domain.span, 1)).toFloat() * plot.width
        drawLine(grid, Offset(x, plot.top), Offset(x, plot.bottom), 1f)
        val text = measurer.measure(ChartTicks.label(f), label)
        drawText(text, topLeft = Offset(x - text.size.width / 2f, plot.bottom + 4f))
    }
    // A chart in a narrow panel has no room for titles; the panel's own heading says what it is.
    if (compact) return
    val titleStyle = TextStyle(color = StarColors.textSecondary, fontSize = 11.sp)
    val xt = measurer.measure(xTitle, titleStyle)
    drawText(xt, topLeft = Offset(plot.left + (plot.width - xt.size.width) / 2f, size.height - xt.size.height - 2f))
    val yt = measurer.measure(yTitle, titleStyle)
    rotate(-90f, pivot = Offset(10f + yt.size.height / 2f, plot.top + plot.height / 2f)) {
        drawText(yt, topLeft = Offset(10f + yt.size.height / 2f - yt.size.width / 2f, plot.top + plot.height / 2f - yt.size.height / 2f))
    }
}

@Composable
private fun Tooltip(hover: Hover, at: Offset, bounds: androidx.compose.ui.unit.IntSize) {
    val density = LocalDensity.current
    val width = with(density) { 170.dp.roundToPx() }
    val tall = with(density) { (18 * hover.lines.size + 14).dp.roundToPx() }
    // Above and to the right of the mark, or to its left and below when that would leave the chart.
    var x = at.x.roundToInt() + 12
    var y = at.y.roundToInt() - tall - 8
    if (x + width > bounds.width) x = at.x.roundToInt() - width - 12
    if (y < 0) y = at.y.roundToInt() + 12
    Column(
        Modifier
            .offset { IntOffset(x.coerceAtLeast(0), y.coerceAtLeast(0)) }
            .width(170.dp)
            .clip(RoundedCornerShape(6.dp))
            .background(StarColors.appBackground)
            .border(1.dp, StarColors.gray.copy(alpha = 0.5f), RoundedCornerShape(6.dp))
            .padding(8.dp),
        verticalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        hover.lines.forEachIndexed { i, (text, color) ->
            Text(text, color = color ?: StarColors.textPrimary, fontSize = 11.sp, fontWeight = if (i == 0) FontWeight.Bold else FontWeight.Normal)
        }
    }
}

/** The legend: a colour and the offset it stands for, for each offset showing on a chart. */
@Composable
fun OffsetLegend(offsets: List<Int>, modifier: Modifier = Modifier) {
    Column(
        modifier.clip(RoundedCornerShape(6.dp)).background(StarColors.prefsCard).padding(8.dp),
        verticalArrangement = Arrangement.spacedBy(5.dp),
    ) {
        Text(localized("ui.neighbor_offset"), color = StarColors.textPrimary, fontSize = 11.sp, fontWeight = FontWeight.Bold)
        for (offset in offsets) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Box(Modifier.width(16.dp).height(3.dp).clip(RoundedCornerShape(2.dp)).background(offsetColor(offset)))
                Text(AlignmentCharts.offsetLabel(offset), color = StarColors.textSecondary, fontSize = 11.sp)
            }
        }
    }
}
