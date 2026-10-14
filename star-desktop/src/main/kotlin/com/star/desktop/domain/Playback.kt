package com.star.desktop.domain

/** Playback direction (macOS `VideoPlayMode`). */
enum class VideoPlayMode { FORWARD, REVERSE }

/**
 * Fast-skip strategy for the fast-previous/next buttons (macOS `FastAdvancementType`):
 * jump a fixed amount, or scan to the next frame whose chosen outlier category is non-empty.
 */
enum class FastAdvancementType(private val rawValue: String, private val descriptionKey: String) {
    NORMAL("normal", "ui.fast_skip_n_frames"),
    SKIP_EMPTIES("skipEmpties", "ui.skip_all_frames_without_outliers"),
    TO_NEXT_POSITIVE("toNextPositive", "ui.skip_to_next_frame_with_a_positive_outlier"),
    TO_NEXT_NEGATIVE("toNextNegative", "ui.skip_to_next_frame_with_a_negative_outlier"),
    TO_NEXT_UNKNOWN("toNextUnknown", "ui.skip_to_next_frame_with_a_unknown_outlier");

    /** The strategy's name in the picker (macOS `localizedName`: the shared `fast_advancement.*` entries). */
    val label: String get() = com.star.desktop.i18n.localized("fast_advancement.$rawValue")

    /** What the fast buttons do in this strategy; [amount] is the number of frames the normal one moves by. */
    fun description(amount: Int): String =
        if (this == NORMAL) com.star.desktop.i18n.localized(descriptionKey, amount) else com.star.desktop.i18n.localized(descriptionKey)

    companion object {
        /** How many frames the fast buttons can be set to move by (macOS offers 0 to 50). */
        const val MAX_SKIP_AMOUNT = 50
        const val DEFAULT_SKIP_AMOUNT = 20
    }
}
