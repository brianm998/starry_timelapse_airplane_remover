package com.star.ui

import androidx.compose.foundation.Canvas
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.*
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import com.star.ui.theme.StarColors
import com.star.viewmodel.OutlierGroupState

/**
 * Colored bounding-box overlay for outlier groups.
 * Mirrors OutlierGroupView.swift exactly — colors from OutlierGroupViewModel.swift.
 *
 * State colors (confirmed from OutlierGroupViewModel.swift groupColor):
 *   selected → orange
 *   will-remove → red
 *   will-keep  → green
 *   undecided  → blue
 *
 * Box fill: alpha 0.5 normally, 0.125 when selected/arrow-selected.
 * White border at alpha 0.33.
 *
 * Direction arrows toward the group from the frame edges are drawn when selected.
 */
@Composable
fun OutlierOverlay(
    groups: List<OutlierGroupState>,
    zoom: Float,
    offsetX: Float,
    offsetY: Float,
    modifier: Modifier = Modifier,
) {
    Canvas(modifier) {
        groups.forEach { group ->
            drawGroup(group, zoom, offsetX, offsetY)
        }
    }
}

private fun DrawScope.drawGroup(
    group: OutlierGroupState,
    zoom: Float,
    offsetX: Float,
    offsetY: Float,
) {
    val b = group.bounds
    val screenLeft   = b.minX * zoom + offsetX
    val screenTop    = b.minY * zoom + offsetY
    val screenWidth  = b.width * zoom
    val screenHeight = b.height * zoom

    val topLeft = Offset(screenLeft, screenTop)
    val size = Size(screenWidth, screenHeight)

    val fillAlpha = if (group.isSelected) StarColors.boxSelectAlpha else StarColors.boxFillAlpha
    val boxColor = group.groupColor

    // Filled rect
    drawRect(
        color = boxColor.copy(alpha = fillAlpha),
        topLeft = topLeft,
        size = size,
    )

    // White border
    drawRect(
        color = Color.White.copy(alpha = StarColors.boxBorderAlpha),
        topLeft = topLeft,
        size = size,
        style = Stroke(width = 1f),
    )

    // Colored border on top
    drawRect(
        color = boxColor.copy(alpha = 0.8f),
        topLeft = topLeft,
        size = size,
        style = Stroke(width = 1f),
    )

    // Direction arrows when selected (pointing inward from frame edges toward the group center)
    if (group.isSelected) {
        val centerX = screenLeft + screenWidth / 2f
        val centerY = screenTop + screenHeight / 2f
        val arrowColor = group.arrowColor

        // Top arrow (↓): from top edge of canvas down to group
        drawLine(arrowColor, Offset(centerX, 0f), Offset(centerX, screenTop), strokeWidth = 1.5f)
        // Bottom arrow (↑): from bottom edge up to group
        drawLine(arrowColor, Offset(centerX, size.height), Offset(centerX, screenTop + screenHeight), strokeWidth = 1.5f)
        // Left arrow (→): from left edge to group
        drawLine(arrowColor, Offset(0f, centerY), Offset(screenLeft, centerY), strokeWidth = 1.5f)
        // Right arrow (←): from right edge to group
        drawLine(arrowColor, Offset(size.width, centerY), Offset(screenLeft + screenWidth, centerY), strokeWidth = 1.5f)
    }
}
