package com.star.desktop.domain

/** Moving from frame to frame with the arrows and the fast buttons (macOS `transition(numberOfFrames:)`). */
object FrameNavigation {
    /**
     * The frame [delta] steps from [current]. With one frame selected (or none) that is [delta] frames along the sequence, stopping at its
     * ends. With several selected it is [delta] frames along the *selection*, in frame order and wrapping round, so the arrows page through
     * just the frames being worked on; a current frame that is not among them stays where it is.
     */
    fun step(current: Int, delta: Int, frameCount: Int, selection: Set<Int>): Int {
        if (selection.size > 1) {
            val sorted = selection.sorted()
            val position = sorted.indexOf(current)
            if (position < 0) return current
            return sorted[((position + delta) % sorted.size + sorted.size) % sorted.size]
        }
        return (current + delta).coerceIn(0, (frameCount - 1).coerceAtLeast(0))
    }
}
