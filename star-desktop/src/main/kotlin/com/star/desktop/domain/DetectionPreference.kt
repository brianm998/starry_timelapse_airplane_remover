package com.star.desktop.domain

import com.star.proto.DetectionType

/**
 * The detection type the user last chose, as the macOS app keeps it (`userPreferences.processingType`, the type's own name: "mild", "strong",
 * "stronger", "excessive", "custom"). New sequences start from it, so someone who always wants Excessive does not have to say so every time.
 */
object DetectionPreference {
    const val KEY = "processingType"

    fun toPref(type: DetectionType): String = type.name.removePrefix("DETECTION_").lowercase()

    /** The type the stored text names, or null for none or one this client does not know (a newer app's). */
    fun fromPref(text: String?): DetectionType? =
        DetectionType.entries.firstOrNull { it != DetectionType.UNRECOGNIZED && toPref(it) == text?.trim()?.lowercase() }
}
