package com.star.desktop.domain

import kotlin.math.abs

/**
 * A frame rate as the shared preferences file holds it. The macOS app writes its `FrameRate` enum the way Swift codes one with associated values:
 * a standard rate is its case name over an empty object (`{"fps_29_97":{}}`), and a custom one is `{"custom":{"_0":12.5}}`. The Kotlin client reads
 * and writes the same, so a rate chosen in either app is the one the other opens with.
 */
object FrameRatePref {
    /** The standard rates and what each is called in the file. */
    private val STANDARD = listOf(
        "fps_24" to 24.0, "fps_25" to 25.0, "fps_30" to 30.0, "fps_50" to 50.0, "fps_60" to 60.0,
        "fps_23_976" to 23.976, "fps_29_97" to 29.97, "fps_59_94" to 59.94,
    )

    /** The rate the stored value names, or null for none or one that is not a rate. */
    fun fromPref(stored: Any?): Double? {
        val map = stored as? Map<*, *> ?: return null
        val entry = map.entries.singleOrNull() ?: return null
        val key = entry.key as? String ?: return null
        if (key == "custom") {
            val value = ((entry.value as? Map<*, *>)?.get("_0") as? Number)?.toDouble() ?: return null
            return value.takeIf { it.isFinite() && it > 0 }
        }
        return STANDARD.firstOrNull { it.first == key }?.second
    }

    /** The stored form of [rate]: a standard rate by its name, any other as custom. */
    fun toPref(rate: Double): Map<String, Any> {
        val standard = STANDARD.firstOrNull { abs(it.second - rate) < 1e-9 }
        return if (standard != null) mapOf(standard.first to emptyMap<String, Any>()) else mapOf("custom" to mapOf("_0" to rate))
    }
}
