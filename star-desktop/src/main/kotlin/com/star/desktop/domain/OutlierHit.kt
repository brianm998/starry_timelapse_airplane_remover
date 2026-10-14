package com.star.desktop.domain

import com.star.proto.OutlierGroup

/**
 * Which outlier group a pointer position means (macOS: every group is a view the size of its bounding box, smaller ones on top, and
 * the arrows at the frame's edges are views of their own).
 */
object OutlierHit {
    /**
     * The group whose bounding box contains image pixel ([x], [y]); where boxes overlap, the smallest, as macOS stacks them so the one
     * inside another can still be reached. Null if none does.
     */
    fun smallestBoxContaining(groups: List<OutlierGroup>, x: Int, y: Int): OutlierGroup? =
        groups
            .filter { x in it.bounds.minX..it.bounds.maxX && y in it.bounds.minY..it.bounds.maxY }
            .minByOrNull { (it.bounds.maxX - it.bounds.minX + 1).toLong() * (it.bounds.maxY - it.bounds.minY + 1) }

    /** A rectangle in image pixels, edges inclusive of the left/top and exclusive of the right/bottom. */
    data class Rect(val left: Float, val top: Float, val right: Float, val bottom: Float) {
        fun contains(x: Float, y: Float) = x >= left && x < right && y >= top && y < bottom
    }

    /**
     * Where the four arrows of [group] sit (left, top, right, bottom), as the rectangle each fits in: each points in from just
     * outside the frame to the line through the group's centre, [arrowLength] long and [arrowHeight] across.
     */
    fun arrowRects(group: OutlierGroup, frameWidth: Float, frameHeight: Float, arrowLength: Float, arrowHeight: Float): List<Rect> {
        val b = group.bounds
        val cx = b.minX + (b.maxX - b.minX + 1) / 2f
        val cy = b.minY + (b.maxY - b.minY + 1) / 2f
        return listOf(
            Rect(-arrowLength, cy - arrowHeight / 2f, 0f, cy + arrowHeight / 2f),                          // left, points right
            Rect(cx - arrowHeight / 2f, -arrowLength, cx + arrowHeight / 2f, 0f),                          // top, points down
            Rect(frameWidth, cy - arrowHeight / 2f, frameWidth + arrowLength, cy + arrowHeight / 2f),      // right, points left
            Rect(cx - arrowHeight / 2f, frameHeight, cx + arrowHeight / 2f, frameHeight + arrowLength),    // bottom, points up
        )
    }

    /**
     * The group whose arrow is under image point ([x], [y]): only among groups whose arrows are showing ([showsArrows]), since a
     * hidden arrow is not there to click. Where arrows overlap, the smaller group's wins.
     */
    fun arrowGroupAt(
        groups: List<OutlierGroup>,
        x: Float,
        y: Float,
        frameWidth: Float,
        frameHeight: Float,
        arrowLength: Float,
        arrowHeight: Float,
        showsArrows: (OutlierGroup) -> Boolean,
    ): OutlierGroup? =
        groups
            .filter { showsArrows(it) && arrowRects(it, frameWidth, frameHeight, arrowLength, arrowHeight).any { r -> r.contains(x, y) } }
            .minByOrNull { it.size }
}
