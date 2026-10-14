package com.star.desktop.domain

import com.star.desktop.i18n.localized

/**
 * The editing tools (macOS `ImageSequenceViewModel.ToolType`). [selectable] is the exact order
 * bound to number keys 1–8. [NONE] is auto-selected when the clean method doesn't use outliers.
 *
 * [iconBaseName] resolves to `icons/<name>.png` in classpath resources (re-exported from the macOS
 * asset catalog). Per-tool selection colors live in `ui/theme/StarColors`.
 *
 * [cursorBaseName] is the base for the tool's frame cursors — `icons/<base>_crosshair.png` (hover)
 * and `icons/<base>_pointing.png` (drag / group hover). Null for [NONE] (system arrow). Note these
 * bases differ from [iconBaseName] (e.g. TRASH's cursor is `delete_trash`, not `add_to_trash_icon`).
 */
enum class ToolType(private val nameKey: String, val iconBaseName: String, val cursorBaseName: String?) {
    REMOVE("tool.remove", "remove_icon", "remove"),
    KEEP("tool.keep", "keep_icon", "keep"),
    RAZOR("tool.razor", "razor_icon", "razor"),
    SHOVEL("tool.shovel", "shovel_icon", "shovel"),
    TRASH("tool.trash", "add_to_trash_icon", "delete_trash"),
    REMOVE_FROM_TRASH("tool.removeFromTrash", "remove_from_trash_icon", "extract_trash"),
    MULTI("tool.multi", "multi_choice_icon", "multi"),
    INFORMATION("tool.information", "info_icon", "info"),
    NONE("tool.none", "shovel_icon", null);

    /**
     * The tool's name in the user's language. Shares its keys with the macOS app's
     * `ToolType.localizedName`, so the two clients cannot end up calling the same tool
     * two different things.
     */
    val displayName: String get() = localized(nameKey)

    /** Hover text for the tool, from the shared catalogue (`tool.help.<macOS rawValue>`). */
    val helpText: String get() = localized("tool.help.${nameKey.removePrefix("tool.")}")

    /** Whether this tool only sets a keep/remove decision (mappable to `Outlier.SetDecisions` today). */
    val setsDecisionOnly: Boolean get() = this == REMOVE || this == KEEP

    /**
     * Whether this tool acts on a dragged rectangle (rubber-band) rather than a single group click.
     * MULTI opens the multi-select sheet; RAZOR/SHOVEL/TRASH/REMOVE_FROM_TRASH apply via `Outlier.ApplyAreaTool`;
     * REMOVE/KEEP set every group inside the box (`Outlier.SetDecisionsInArea`); INFORMATION lists them in the outlier window.
     * (Only NONE drags to pan, and any tool pans with the scroll wheel or a middle- or Alt-drag.)
     */
    val isAreaDrag: Boolean
        get() = this == MULTI || this == RAZOR || this == SHOVEL || this == TRASH || this == REMOVE_FROM_TRASH ||
            this == REMOVE || this == KEEP || this == INFORMATION

    companion object {
        /** Tools bound to shortcuts 1–8, in order. */
        val selectable = listOf(REMOVE, KEEP, RAZOR, SHOVEL, TRASH, REMOVE_FROM_TRASH, MULTI, INFORMATION)

        /** The tool for the 1-based number-key shortcut, or null if out of range. */
        fun forShortcut(number: Int): ToolType? = selectable.getOrNull(number - 1)
    }
}
