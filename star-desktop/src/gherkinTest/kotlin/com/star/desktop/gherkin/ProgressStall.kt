package com.star.desktop.gherkin

/**
 * Fails a processing wait whose progress line has stopped changing. One per wait: it starts timing when it is made, every change of the line
 * (the node appearing included) restarts the time, and [observe] throws once the line has sat unchanged for [limitNs].
 */
internal class ProgressStall(private val limitNs: Long, private val clock: () -> Long = System::nanoTime) {
    private var state: String? = null
    private var changedAt = clock()

    /** Call on every poll with the progress line, or null when the node is not there. */
    fun observe(current: String?) {
        val t = clock()
        if (current != null && current != state) {
            state = current
            changedAt = t
            return
        }
        val stuck = t - changedAt
        if (stuck >= limitNs) {
            throw DesktopFeatureRunner.RunnerError(
                "processing made no progress for ${stuck / 60_000_000_000L} min, stuck at ${state ?: "(no progress line)"}"
            )
        }
    }
}
