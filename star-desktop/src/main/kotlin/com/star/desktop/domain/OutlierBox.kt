package com.star.desktop.domain

import com.star.proto.OutlierGroup

/**
 * The outlier groups a dragged box selects: the ones whose whole bounding box is inside it, as StarCore's
 * `foreachOutlierGroupMulti(between:and:)` decides (a group that is only partly inside is not touched), largest first
 * (the order macOS lists them in the outlier window). The box is given by its two corners in either order, in image pixels;
 * like StarCore it truncates them to whole pixels.
 */
fun groupsInsideBox(groups: List<OutlierGroup>, x1: Float, y1: Float, x2: Float, y2: Float): List<OutlierGroup> {
    val minX = minOf(x1, x2).toInt()
    val maxX = maxOf(x1, x2).toInt()
    val minY = minOf(y1, y2).toInt()
    val maxY = maxOf(y1, y2).toInt()
    return groups
        .filter { it.bounds.minX >= minX && it.bounds.maxX <= maxX && it.bounds.minY >= minY && it.bounds.maxY <= maxY }
        .sortedByDescending { it.size }
}
