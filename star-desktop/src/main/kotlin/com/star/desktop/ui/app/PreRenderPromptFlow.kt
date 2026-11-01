package com.star.desktop.ui.app

import com.star.proto.VideoEncodeSettings
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * The pre-processing render prompt as a sequence of steps (macOS `PreProcessingRenderFlow`): the question, then, after Yes, the render
 * options. Pure, so the flow can be tested without an [AppViewModel], which acts on what these return.
 */
class PreRenderPromptFlow {
    enum class Step { CLOSED, ASKING, CHOOSING }

    /** How processing starts: the arguments of `AppViewModel.confirmStartProcessing`. */
    data class Start(val autoRender: Boolean, val dontAskAgain: Boolean, val settings: VideoEncodeSettings? = null)

    private val _step = MutableStateFlow(Step.CLOSED)
    val step: StateFlow<Step> = _step.asStateFlow()

    fun open() { _step.value = Step.ASKING }

    /** Yes: on to the options. Nothing starts yet. */
    fun yes() { if (_step.value == Step.ASKING) _step.value = Step.CHOOSING }

    /** Cancel in the options: back to the question, with nothing started. */
    fun cancelOptions() { if (_step.value == Step.CHOOSING) _step.value = Step.ASKING }

    /** "Use These Settings": how processing starts, with [settings] for the render at its end. null if the options were not showing. */
    fun confirm(settings: VideoEncodeSettings): Start? {
        if (_step.value != Step.CHOOSING) return null
        _step.value = Step.CLOSED
        return Start(autoRender = true, dontAskAgain = false, settings = settings)
    }

    fun no(): Start { reset(); return Start(autoRender = false, dontAskAgain = false) }

    fun dontAskAgain(): Start { reset(); return Start(autoRender = false, dontAskAgain = true) }

    /** The prompt is put away, or the sequence closed. */
    fun reset() { _step.value = Step.CLOSED }
}
