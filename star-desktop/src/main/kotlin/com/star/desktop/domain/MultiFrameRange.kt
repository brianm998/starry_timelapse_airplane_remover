package com.star.desktop.domain

import com.star.desktop.i18n.localized

/**
 * Which frames a multi-frame outlier edit touches (macOS `MultiSelectionType`). [indices] maps the
 * choice to an inclusive [start, end] frame range given the current frame, frame count, and N.
 * [labelKey] is the catalogue entry for the choice's name (`multi_selection.<case>`).
 */
enum class MultiFrameRange(private val labelKey: String) {
    ALL("multi_selection.all"),
    ALL_AFTER("multi_selection.allAfter"),
    ALL_BEFORE("multi_selection.allBefore"),
    SOME_AFTER("multi_selection.someAfter"),
    SOME_BEFORE("multi_selection.someBefore");

    val label: String get() = localized(labelKey)

    val needsCount: Boolean get() = this == SOME_AFTER || this == SOME_BEFORE

    fun indices(current: Int, count: Int, n: Int): Pair<Int, Int> = when (this) {
        ALL -> 0 to (count - 1)
        ALL_AFTER -> current to (count - 1)
        ALL_BEFORE -> 0 to current
        SOME_AFTER -> current to (current + n).coerceAtMost(count - 1)
        SOME_BEFORE -> (current - n).coerceAtLeast(0) to current
    }

    /** How many frames the choice touches. */
    fun frameCount(current: Int, count: Int, n: Int): Int = indices(current, count, n).let { (s, e) -> (e - s + 1).coerceAtLeast(0) }

    /**
     * The sentence that says what an action will do to the frames of this choice, as macOS's sheets show under the choices: [prefix] is
     * the action (`ui.overlap.paint`, `ui.area.remove_overlaps`, …) and the catalogue has it for all frames (`.all`), from here to the
     * end (`.after`) and from the start to here (`.before`). The choices with a count the user types have no sentence.
     */
    fun summary(prefix: String, current: Int, count: Int): String? = when (this) {
        ALL -> localized("$prefix.all", count)
        ALL_AFTER -> localized("$prefix.after", frameCount(current, count, 0), current)
        ALL_BEFORE -> localized("$prefix.before", frameCount(current, count, 0), current)
        SOME_AFTER, SOME_BEFORE -> null
    }
}
