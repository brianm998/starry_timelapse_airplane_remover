package com.star.desktop.domain

/**
 * The editing tools (macOS `ImageSequenceViewModel.ToolType`). [selectable] is the exact order
 * bound to number keys 1–8. [NONE] is auto-selected when the clean method doesn't use outliers.
 *
 * [iconBaseName] resolves to `icons/<name>.png` in classpath resources (re-exported from the macOS
 * asset catalog). Per-tool selection colors live in `ui/theme/StarColors`.
 */
enum class ToolType(val displayName: String, val iconBaseName: String) {
    REMOVE("Remove", "remove_icon"),
    KEEP("Keep", "keep_icon"),
    RAZOR("Razor", "razor_icon"),
    SHOVEL("Shovel", "shovel_icon"),
    TRASH("Trash", "add_to_trash_icon"),
    REMOVE_FROM_TRASH("Get from Trash", "remove_from_trash_icon"),
    MULTI("Multi", "multi_choice_icon"),
    INFORMATION("Information", "info_icon"),
    NONE("None", "shovel_icon");

    /** Whether this tool only sets a keep/remove decision (mappable to `Outlier.SetDecisions` today). */
    val setsDecisionOnly: Boolean get() = this == REMOVE || this == KEEP

    companion object {
        /** Tools bound to shortcuts 1–8, in order. */
        val selectable = listOf(REMOVE, KEEP, RAZOR, SHOVEL, TRASH, REMOVE_FROM_TRASH, MULTI, INFORMATION)

        /** The tool for the 1-based number-key shortcut, or null if out of range. */
        fun forShortcut(number: Int): ToolType? = selectable.getOrNull(number - 1)
    }
}
