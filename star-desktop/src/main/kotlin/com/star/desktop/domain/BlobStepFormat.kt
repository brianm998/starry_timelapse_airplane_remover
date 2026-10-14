package com.star.desktop.domain

import java.util.Locale

/** How a blob step's parameter is shown and read in the Blob Processing window (macOS `StepRowView`). */
object BlobStepFormat {
    /** An integer parameter as a whole number, any other with two decimals. */
    fun show(value: Double, isInteger: Boolean): String =
        if (isInteger) value.toLong().toString() else String.format(Locale.ROOT, "%.2f", value)

    /** What was typed as the number it means, or null if it is not one (the field then goes back to what it was). An integer parameter takes whole numbers only. */
    fun parse(text: String, isInteger: Boolean): Double? {
        val t = text.trim()
        return if (isInteger) t.toIntOrNull()?.toDouble() else t.toDoubleOrNull()?.takeIf { it.isFinite() }
    }
}
