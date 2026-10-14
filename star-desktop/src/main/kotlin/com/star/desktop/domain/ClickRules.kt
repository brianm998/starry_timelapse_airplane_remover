package com.star.desktop.domain

import kotlin.math.abs

/**
 * What a click on the frame means. macOS puts the tap on the outlier group's own view, so a click that lands on a group acts at once,
 * and only a click that lands on nothing can be half of a double-click that zooms; the view here does the same, so a group's click is
 * not held back waiting to see whether a second one follows.
 */
object ClickRules {
    enum class GroupClick {
        /** Apply the tool to the group: set its decision, dump it in the trash, show its details. */
        APPLY_TOOL,

        /** Open the multi-choice sheet for the group (propagate its decision to the frames it overlaps in). */
        OPEN_MULTI_CHOICE,
    }

    /**
     * What clicking a group does with [tool]. The multi tool always opens the sheet. With the "Multi Choice" switch on, so does any tool
     * on a group that has a decision ([decided]); Trash and Information keep their meaning (macOS checks them first).
     */
    fun groupClick(tool: ToolType, multiChoice: Boolean, decided: Boolean): GroupClick = when {
        tool == ToolType.TRASH || tool == ToolType.INFORMATION -> GroupClick.APPLY_TOOL
        tool == ToolType.MULTI -> GroupClick.OPEN_MULTI_CHOICE
        multiChoice && decided -> GroupClick.OPEN_MULTI_CHOICE
        else -> GroupClick.APPLY_TOOL
    }

    /** A click that hit nothing: when and where (canvas pixels). */
    data class EmptyClick(val timeMillis: Long, val x: Float, val y: Float)

    /** Whether a click at ([x], [y]) at [timeMillis] is the second of a double-click after [previous] (which also hit nothing). */
    fun completesDoubleClick(previous: EmptyClick?, timeMillis: Long, x: Float, y: Float, timeoutMillis: Long, slop: Float): Boolean =
        previous != null &&
            timeMillis - previous.timeMillis in 0..timeoutMillis &&
            abs(x - previous.x) <= slop && abs(y - previous.y) <= slop
}
