package com.star.desktop.ui.components

import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import com.star.desktop.ui.theme.StarColors
import com.star.proto.GetHorizonOverlayResponse
import com.star.proto.HorizonOverlayKind

/**
 * The colour a frame's horizon line is drawn in, as on macOS: orange while the frame waits for a horizon refinement
 * (whatever the line is), else green for a painted reference, blue for a merged (interpolated) horizon, and white for the
 * raw detected one.
 */
fun horizonLineColor(kind: HorizonOverlayKind, pending: Boolean): Color = when {
    pending -> StarColors.orange
    kind == HorizonOverlayKind.HORIZON_OVERLAY_KIND_REFERENCE -> StarColors.green
    kind == HorizonOverlayKind.HORIZON_OVERLAY_KIND_MERGED -> StarColors.blue
    else -> StarColors.white
}

/**
 * Draw a horizon [overlay] as a polyline. The overlay's columns span the image's width and its Y values are in a space
 * [GetHorizonOverlayResponse.getHeight] tall; [toCanvas] maps a point of the image (`x` in 0..[imageWidth], `y` in
 * 0..[imageHeight]) to where it is drawn, so the same line can be drawn on a thumbnail, a filmstrip cell, or the full
 * frame at any zoom.
 */
fun DrawScope.drawHorizonLine(
    overlay: GetHorizonOverlayResponse,
    imageWidth: Float,
    imageHeight: Float,
    color: Color,
    strokeWidth: Float,
    toCanvas: (Offset) -> Offset,
) {
    val ys = overlay.yPerColumnList
    if (!overlay.exists || ys.isEmpty() || overlay.height <= 0) return
    val path = Path()
    val columnWidth = imageWidth / ys.size
    val rowScale = imageHeight / overlay.height
    ys.forEachIndexed { i, y ->
        val p = toCanvas(Offset(i * columnWidth, y * rowScale))
        if (i == 0) path.moveTo(p.x, p.y) else path.lineTo(p.x, p.y)
    }
    drawPath(path, color = color, style = Stroke(width = strokeWidth))
}
