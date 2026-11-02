package com.star.desktop.domain

import com.star.desktop.i18n.localized
import com.star.proto.FrameExtraction

/**
 * What the system-tray icon says about the run in progress, as plain values (macOS `MenuBarStatus`, the menu-bar wand's content).
 *
 * Nothing here measures progress: the stage line and the time left are the ones [ProcessingHeadline] gives the processing screen, the steps are
 * its [StepRow]s, and the frame count is the one under its title.
 */
sealed interface MenuBarStatus {
    /** Nothing is running, or no sequence is open. */
    data object Idle : MenuBarStatus

    /**
     * A processing run, as the processing screen shows it. [stage] is what star is doing now ([ProcessingHeadline.text]); null while it has nothing to say.
     * [fraction] is [framesDone] over [frameCount], 0 for a sequence with no frames. [overall] is the time left in all, null until a rate is known.
     */
    data class Processing(
        val sequenceName: String,
        val stage: String?,
        val framesDone: Int,
        val frameCount: Int,
        val fraction: Float,
        val overall: String?,
    ) : MenuBarStatus

    /** Rendering the video, [fraction] of the way (0 to 1). */
    data class Rendering(val fraction: Float) : MenuBarStatus

    /**
     * The lines of the tray menu. A tray menu holds text only, so the progress bar is drawn with block characters ([textBar]); the macOS panel
     * draws a real one.
     */
    fun lines(): List<String> = when (this) {
        Idle -> listOf(localized("ui.menu_bar.idle"))
        is Rendering -> listOf(localized("ui.menu_bar.rendering_video"), textBar(fraction))
        is Processing -> listOfNotNull(
            sequenceName,
            stage,
            textBar(fraction),
            localized("progress.frames_complete", framesDone, frameCount),
            overall,
        )
    }

    companion object {
        /**
         * [sequenceName] is null when no sequence is open, which is idle whatever the flags say. [steps] are the processing screen's rows, [hasPlan] its
         * `graph_built`, [statusText] what the run is doing before it has operations (said in place of a stage), and [secondsRemaining] the per-step time left
         * from the same [StepRateTracker] the screen reads. Rendering wins over a processing run, as in the gui.
         */
        fun of(
            sequenceName: String?,
            isProcessing: Boolean,
            isRendering: Boolean,
            renderFraction: Float,
            steps: List<StepRow>,
            extraction: FrameExtraction?,
            hasPlan: Boolean,
            statusText: String?,
            framesComplete: Int,
            frameCount: Int,
            secondsRemaining: (StepRow) -> Double?,
        ): MenuBarStatus {
            if (sequenceName == null) return Idle
            if (isRendering) return Rendering(renderFraction.coerceIn(0f, 1f))
            if (!isProcessing) return Idle
            val stage = ProcessingHeadline.text(steps, extraction, hasPlan, framesComplete, frameCount)
            return Processing(
                sequenceName = sequenceName,
                stage = stage ?: statusText,
                framesDone = framesComplete,
                frameCount = frameCount,
                fraction = if (frameCount > 0) framesComplete.toFloat() / frameCount else 0f,
                overall = ProcessingHeadline.overallText(steps, secondsRemaining),
            )
        }

        private const val BAR_CELLS = 12

        /** "███████░░░░░ 58%": a progress bar a text-only menu can show. */
        fun textBar(fraction: Float): String {
            val f = fraction.coerceIn(0f, 1f)
            val filled = (f * BAR_CELLS).toInt()
            return "█".repeat(filled) + "░".repeat(BAR_CELLS - filled) + " " + (f * 100).toInt() + "%"
        }
    }
}
