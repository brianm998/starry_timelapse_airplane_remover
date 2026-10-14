package com.star.desktop.domain

import java.util.Locale

/**
 * What the settings sheet accepts in a number field: a number from [min] to [max], both inclusive (macOS's `EditableNumberView` excludes its upper
 * bound, so 8 was refused where "1 to 8" was offered). Anything else is not applied and is said so, and Save waits until it is put right.
 */
object FieldInput {
    /** The whole number [text] says, if it is within [min]..[max]. */
    fun int(text: String, min: Int, max: Int): Int? = text.trim().toIntOrNull()?.takeIf { it in min..max }

    /** The number [text] says, if it is finite and within [min]..[max]. */
    fun double(text: String, min: Double, max: Double): Double? = text.trim().toDoubleOrNull()?.takeIf { it.isFinite() && it in min..max }

    /** What may be typed in a whole-number field: digits. */
    fun wholeNumberChars(text: String): String = text.filter { it.isDigit() }

    /** What may be typed in a decimal field: digits and a point. */
    fun decimalChars(text: String): String = text.filter { it.isDigit() || it == '.' }

    /** A bound as the message says it: "4" or "0.001", never "4.0". */
    fun bound(value: Double): String = when {
        value == Math.rint(value) -> value.toLong().toString()
        else -> String.format(Locale.ROOT, "%g", value).trimEnd('0').trimEnd('.')
    }
}
