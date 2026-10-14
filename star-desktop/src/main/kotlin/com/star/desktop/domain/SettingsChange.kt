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
     * Whether the button works. Not while a run is going, unless the change contradicts finished work: over a live run the button is the
     * one thing that makes a change reach the frames the run has not got to.
     */
    fun canProcess(isProcessing: Boolean): Boolean = !isProcessing || contradictsFinishedWork

    companion object {
        /** Nothing to warn about: what the sheet shows until the daemon has answered, and when it cannot. */
        val NONE = SettingsChange(emptyList(), false)

        fun of(preview: ConfigChangePreview?): SettingsChange =
            preview?.let { SettingsChange(it.staleStagesList.toList(), it.contradictsFinishedWork) } ?: NONE
    }
}
