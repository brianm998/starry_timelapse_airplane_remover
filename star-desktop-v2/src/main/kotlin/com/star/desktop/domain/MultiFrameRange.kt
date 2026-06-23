package com.star.desktop.domain

/**
 * Which frames a multi-frame outlier edit touches (macOS `MultiSelectionType`). [indices] maps the
 * choice to an inclusive [start, end] frame range given the current frame, frame count, and N.
 */
enum class MultiFrameRange(val label: String) {
    ALL("All frames"),
    ALL_AFTER("This frame to the end"),
    ALL_BEFORE("The start to this frame"),
    SOME_AFTER("This frame and the next N"),
    SOME_BEFORE("The previous N and this frame");

    val needsCount: Boolean get() = this == SOME_AFTER || this == SOME_BEFORE

    fun indices(current: Int, count: Int, n: Int): Pair<Int, Int> = when (this) {
        ALL -> 0 to (count - 1)
        ALL_AFTER -> current to (count - 1)
        ALL_BEFORE -> 0 to current
        SOME_AFTER -> current to (current + n).coerceAtMost(count - 1)
        SOME_BEFORE -> (current - n).coerceAtLeast(0) to current
    }
}
