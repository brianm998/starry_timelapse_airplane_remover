package com.star.desktop.domain

/** What the user types into the frame-number box (macOS `EditableFrameNumberView`): frames are numbered from 0, as everywhere in the app. */
object FrameNumberInput {
    /** The frame the text names, or null if it is not a whole number in 0 until [frameCount]: such an entry is refused, not clamped. */
    fun parse(text: String, frameCount: Int): Int? {
        val digits = text.filter { it in '0'..'9' }
        val n = digits.toIntOrNull() ?: return null
        return n.takeIf { it in 0 until frameCount }
    }
}
