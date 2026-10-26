package com.star.desktop.domain

import com.star.proto.ConfigChangePreview

/**
 * What the settings sheet says about the settings being edited, as the daemon works it out against the work on disk (macOS
 * `settingsContradictFinishedWork`): a change that decides how the output looks, over frames already written, contradicts them. Only then is
 * there anything to warn about, and the button that goes on is Update, which asks first, instead of Process Now.
 */
data class SettingsChange(val staleStages: List<String>, val contradictsFinishedWork: Boolean) {
    /** The button that goes on: Update once there is finished work this contradicts, since it then changes work that is part done. */
    val processKey: String get() = if (contradictsFinishedWork) "ui.update" else "ui.process_now"

    /**
     * Whether the button reports on the run that is going rather than starting one. Over a live run a change that does not contradict finished
     * work leaves Process Now nothing to do (a second run over the same frames is exactly what it must not start), so it takes the user to the
     * processing status instead; one that does contradict keeps the button as Update, the one thing that makes a change reach the frames the
     * run has not got to.
     */
    fun showsProgress(isProcessing: Boolean): Boolean = isProcessing && !contradictsFinishedWork

    /** The catalogue key of the button's label: [processKey], or Show Progress over a live run it has nothing to change in. */
    fun buttonKey(isProcessing: Boolean): String = if (showsProgress(isProcessing)) "ui.show_progress" else processKey

    companion object {
        /** Nothing to warn about: what the sheet shows until the daemon has answered, and when it cannot. */
        val NONE = SettingsChange(emptyList(), false)

        fun of(preview: ConfigChangePreview?): SettingsChange =
            preview?.let { SettingsChange(it.staleStagesList.toList(), it.contradictsFinishedWork) } ?: NONE
    }
}
