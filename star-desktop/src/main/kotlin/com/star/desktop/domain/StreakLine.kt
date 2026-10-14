package com.star.desktop.domain

import com.star.proto.OutlierGroup
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.sin

/**
 * The straight line the daemon fitted through an outlier group's pixels (`OutlierGroup.line`: Hough `theta` in degrees and `rho` in
 * pixels, `x * cos(theta) + y * sin(theta) = rho`, measured from the top-left corner of the group's bounding box), as the stretch of it
 * that lies inside the box, in image pixels. macOS draws it through the group while the group is hovered or selected.
 */
object StreakLine {
    /** A segment of the line in image pixels. */
    data class Segment(val x1: Float, val y1: Float, val x2: Float, val y2: Float)

    /** The part of [group]'s line inside its bounding box, or null if it has no line or the line does not cross the box. */
    fun segment(group: OutlierGroup): Segment? {
        if (!group.hasLine()) return null
        val b = group.bounds
        return segment(group.line.theta, group.line.rho, (b.maxX - b.minX).toDouble(), (b.maxY - b.minY).toDouble())
            ?.let { Segment(it.x1 + b.minX, it.y1 + b.minY, it.x2 + b.minX, it.y2 + b.minY) }
    }

    /**
     * The part of the line (`theta` in degrees, [rho]) inside the box from (0, 0) to ([width], [height]), in the box's own
     * coordinates; null if the line misses it or only touches a corner.
     *
     * Liang–Barsky clipping of the infinite line, so a line parallel to a side, or through a corner, needs no special case.
     */
    fun segment(theta: Double, rho: Double, width: Double, height: Double): Segment? {
        val rad = Math.toRadians(theta)
        // A point on the line (the foot of the perpendicular from the origin), and the direction along it.
        val x0 = rho * cos(rad)
        val y0 = rho * sin(rad)
        val dx = -sin(rad)
        val dy = cos(rad)

        var t0 = -1e12
        var t1 = 1e12
        // x0 + t*dx within [0, width] and y0 + t*dy within [0, height].
        val edges = arrayOf(
            doubleArrayOf(-dx, x0),
            doubleArrayOf(dx, width - x0),
            doubleArrayOf(-dy, y0),
            doubleArrayOf(dy, height - y0),
        )
        for ((p, q) in edges.map { it[0] to it[1] }) {
            if (abs(p) < 1e-12) {
                if (q < 0) return null            // parallel to this side and outside it
            } else {
                val r = q / p
                if (p < 0) { if (r > t0) t0 = r } else { if (r < t1) t1 = r }
            }
        }
        if (t1 - t0 < 1e-6) return null
        return Segment(
            (x0 + t0 * dx).toFloat(), (y0 + t0 * dy).toFloat(),
            (x0 + t1 * dx).toFloat(), (y0 + t1 * dy).toFloat(),
        )
    }
}
