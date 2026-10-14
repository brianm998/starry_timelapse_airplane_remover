package com.star.desktop.domain

import com.star.desktop.i18n.localized
import com.star.proto.OpenProgress
import com.star.proto.OpenStage

/**
 * What the screen shown while a source opens says (macOS `ImageSequenceLoadingView`): which source, and how far each stage has got. A video
 * is examined (nothing to measure), then its frames are extracted; then every source has its frames loaded.
 */
data class LoadingProgress(val name: String, val stage: Stage, val current: Int, val total: Int) {
    enum class Stage { EXAMINING, EXTRACTING, LOADING }

    /** How far along the ring is, or null while there is nothing to measure. */
    val fraction: Float? get() = if (stage == Stage.EXAMINING || total <= 0) null else (current.toFloat() / total).coerceIn(0f, 1f)

    /** Everything this stage covers is done: the screen says so, and waits on whatever comes next (macOS `amount == 1.0`). */
    val isComplete: Boolean get() = stage != Stage.EXAMINING && total > 0 && current >= total

    val title: String get() = localized("ui.loading_x", name)

    /** The line under the ring. */
    val caption: String
        get() = when (stage) {
            Stage.EXAMINING -> localized("ui.examining_video")
            Stage.EXTRACTING -> if (isComplete) localized("ui.all_n_frames_extracted", total) else localized("ui.n_frames_extracted", current)
            Stage.LOADING -> if (isComplete) localized("ui.all_n_frames_loaded", total) else localized("ui.n_frames_loaded", current)
        }

    /** The state after one more event from the daemon. A name is kept until an event brings a new one. */
    fun after(event: OpenProgress): LoadingProgress = when (event.kindCase) {
        OpenProgress.KindCase.STAGE -> {
            val staged = event.stage
            val next = when (staged.stage) {
                OpenStage.OPEN_STAGE_EXAMINING_VIDEO -> Stage.EXAMINING
                OpenStage.OPEN_STAGE_EXTRACTING_FRAMES -> Stage.EXTRACTING
                OpenStage.OPEN_STAGE_LOADING_FRAMES -> Stage.LOADING
                else -> stage
            }
            LoadingProgress(staged.name.ifEmpty { name }, next, if (next == stage) current else 0, if (next == stage) total else 0)
        }
        OpenProgress.KindCase.PROGRESS -> copy(stage = Stage.EXTRACTING, current = event.progress.current, total = event.progress.total)
        OpenProgress.KindCase.LOADED -> copy(stage = Stage.LOADING, current = event.loaded.loaded, total = event.loaded.total)
        else -> this
    }

    companion object {
        /** Before the daemon has said anything: a video is being looked at, anything else is being loaded. */
        fun starting(name: String, video: Boolean) = LoadingProgress(name, if (video) Stage.EXAMINING else Stage.LOADING, 0, 0)
    }
}
