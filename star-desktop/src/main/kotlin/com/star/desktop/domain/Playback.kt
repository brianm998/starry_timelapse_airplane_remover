package com.star.desktop.domain

/** Playback direction (macOS `VideoPlayMode`). */
enum class VideoPlayMode { FORWARD, REVERSE }

/**
 * Fast-skip strategy for the fast-previous/next buttons (macOS `FastAdvancementType`):
 * jump a fixed amount, or scan to the next frame whose chosen outlier category is non-empty.
 */
enum class FastAdvancementType { NORMAL, SKIP_EMPTIES, TO_NEXT_POSITIVE, TO_NEXT_NEGATIVE, TO_NEXT_UNKNOWN }
