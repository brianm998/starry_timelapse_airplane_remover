package com.star.desktop.ui.windows

import com.star.desktop.data.BlobSource
import com.star.proto.BlobStepsResponse
import com.star.proto.DetectionType
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

/**
 * What the Blob Processing window shows and does (macOS `BlobProcessingView`): the steps of a detection type, and for the custom one the changes
 * the user makes to them. Each change is made by the engine and answered with the steps as they now are, so what is shown is what is in force.
 */
class BlobProcessingModel(private val scope: CoroutineScope, private val repo: BlobSource) {
    private val _steps = MutableStateFlow<BlobStepsResponse?>(null)
    /** The steps on show, for the type last asked for; null until the engine has answered. */
    val steps: StateFlow<BlobStepsResponse?> = _steps.asStateFlow()

    private val _error = MutableStateFlow<String?>(null)
    /** What went wrong with the last thing asked of the engine, or null. */
    val error: StateFlow<String?> = _error.asStateFlow()

    /** Show the steps of [type]. */
    fun load(type: DetectionType) = run { repo.steps(type) }

    /** Make the custom type a copy of [type]. */
    fun copyFrom(type: DetectionType) = run { repo.copyFrom(type) }

    fun setArg(stepIndex: Int, name: String, value: Double) = run { repo.setArg(stepIndex, name, value) }

    fun setDisabled(stepIndex: Int, disabled: Boolean) = run { repo.setDisabled(stepIndex, disabled) }

    private fun run(call: suspend () -> BlobStepsResponse) {
        scope.launch {
            try {
                _steps.value = call()
                _error.value = null
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                _error.value = e.message ?: e.toString()
            }
        }
    }
}
