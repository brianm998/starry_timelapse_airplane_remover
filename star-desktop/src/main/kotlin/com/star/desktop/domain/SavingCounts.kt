package com.star.desktop.domain

/**
 * How many frames are at each stage of being saved after an edit (macOS `FrameSaveQueue`'s counts): an edited frame waits in purgatory a
 * while in case there is more to come, then is queued to save, then is being saved. The daemon reports each frame's stage as a number.
 */
data class SavingCounts(val purgatory: Int, val waiting: Int, val saving: Int) {
    val any: Boolean get() = purgatory + waiting + saving > 0

    companion object {
        const val NOT_SAVING = 0
        const val IN_PURGATORY = 1
        const val SAVE_PENDING = 2
        const val SAVING = 3

        /** The counts for the stage each frame is at, by frame index. */
        fun of(stages: Map<Int, Int>): SavingCounts = SavingCounts(
            purgatory = stages.values.count { it == IN_PURGATORY },
            waiting = stages.values.count { it == SAVE_PENDING },
            saving = stages.values.count { it == SAVING },
        )
    }
}
