package com.star.desktop.ui.components

import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import com.star.desktop.i18n.localized
import com.star.desktop.ui.theme.StarColors
import com.star.proto.GetHorizonOverlayResponse
import com.star.proto.HorizonOverlayKind

/**
 * The colour a frame's horizon line is drawn in, as on macOS: orange while the frame waits for a horizon refinement
 * (whatever the line is), else green for a painted reference, purple for a moving sequence's horizon consensus (the line
 * its output is composited with), blue for a merged (interpolated) horizon, and white for the raw detected one.
 */
fun horizonLineColor(kind: HorizonOverlayKind, pending: Boolean): Color = when {
    pending -> StarColors.orange
    kind == HorizonOverlayKind.HORIZON_OVERLAY_KIND_REFERENCE -> StarColors.green
    kind == HorizonOverlayKind.HORIZON_OVERLAY_KIND_CONSENSUS -> StarColors.purple
    kind == HorizonOverlayKind.HORIZON_OVERLAY_KIND_MERGED -> StarColors.blue
    else -> StarColors.white
}

/**
 * The kinds of horizon line a frame can have, in the order they are drawn (the one the composite reads last, on top) and listed,
 * with the name each is stored under in the preferences file the macOS app shares (`hiddenHorizonLineKinds`, its
 * `HorizonThumbnailOverlay.Kind` raw values).
 */
object HorizonLineKinds {
    val all: List<HorizonOverlayKind> = listOf(
        HorizonOverlayKind.HORIZON_OVERLAY_KIND_INITIAL, HorizonOverlayKind.HORIZON_OVERLAY_KIND_MERGED,
        HorizonOverlayKind.HORIZON_OVERLAY_KIND_CONSENSUS, HorizonOverlayKind.HORIZON_OVERLAY_KIND_REFERENCE,
    )

    fun key(kind: HorizonOverlayKind): String? = when (kind) {
        HorizonOverlayKind.HORIZON_OVERLAY_KIND_INITIAL -> "initial"
        HorizonOverlayKind.HORIZON_OVERLAY_KIND_MERGED -> "merged"
        HorizonOverlayKind.HORIZON_OVERLAY_KIND_CONSENSUS -> "consensus"
        HorizonOverlayKind.HORIZON_OVERLAY_KIND_REFERENCE -> "reference"
        else -> null
    }

    /** The kinds to draw, given the ones the user has hidden (by stored name); a name this build does not know is ignored. */
    fun visible(hidden: Collection<String>): Set<HorizonOverlayKind> = all.filter { key(it) !in hidden }.toSet()

    /** The label of this kind's show/hide switch. */
    fun label(kind: HorizonOverlayKind): String = key(kind)?.let { localized("ui.horizon_line.$it") } ?: ""

    /** The kinds of line [overlay] has.  A daemon from before every line was sent has only the one the composite reads. */
    fun available(overlay: GetHorizonOverlayResponse?): Set<HorizonOverlayKind> = when {
        overlay == null -> emptySet()
        overlay.linesCount > 0 -> overlay.linesList.map { it.kind }.toSet()
        overlay.exists -> setOf(overlay.kind)
        else -> emptySet()
    }
}

/**
 * Draw each of [overlay]'s lines whose kind is in [visible], each in its own colour; the line the composite reads is orange while
 * the frame waits for a refinement.  The lines' columns span the image's width and their Y values are in a space each line's
 * `height` tall; [toCanvas] maps a point of the image (`x` in 0..[imageWidth], `y` in 0..[imageHeight]) to where it is drawn,
 * so the same lines can be drawn on a thumbnail, a filmstrip cell, or the full frame at any zoom.
 */
fun DrawScope.drawHorizonLines(
    overlay: GetHorizonOverlayResponse,
    visible: Set<HorizonOverlayKind>,
    imageWidth: Float,
    imageHeight: Float,
    strokeWidth: Float,
    toCanvas: (Offset) -> Offset,
) {
    if (!overlay.exists) return
    val lines: List<Triple<HorizonOverlayKind, List<Int>, Int>> =
        if (overlay.linesCount > 0) overlay.linesList.map { Triple(it.kind, it.yPerColumnList, it.height) }
        else listOf(Triple(overlay.kind, overlay.yPerColumnList, overlay.height))
    for ((kind, ys, height) in lines) {
        if (kind !in visible) continue
        val color = horizonLineColor(kind, pending = overlay.refinementPending && kind == overlay.kind)
        drawPolyline(ys, height, imageWidth, imageHeight, color, strokeWidth, toCanvas)
    }
}

private fun DrawScope.drawPolyline(
    ys: List<Int>,
    height: Int,
    imageWidth: Float,
    imageHeight: Float,
    color: Color,
    strokeWidth: Float,
    toCanvas: (Offset) -> Offset,
) {
    if (ys.isEmpty() || height <= 0) return
    val path = Path()
    val columnWidth = imageWidth / ys.size
    val rowScale = imageHeight / height
    ys.forEachIndexed { i, y ->
        val p = toCanvas(Offset(i * columnWidth, y * rowScale))
        if (i == 0) path.moveTo(p.x, p.y) else path.lineTo(p.x, p.y)
    }
    drawPath(path, color = color, style = Stroke(width = strokeWidth))
}
