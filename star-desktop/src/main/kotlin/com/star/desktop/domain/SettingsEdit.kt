package com.star.desktop.domain

import com.star.proto.CleanMethod

/**
 * What the settings sheet is editing as of now, which is what its rules read to say which rows apply (macOS `ProcessingSettingsView`'s
 * `.disabled(...)`s): a sky-only sequence has no horizon to find, so every horizon row is moot; a camera that stayed put has no reference
 * horizons to smooth between; a sub-setting means nothing while the setting above it is off.
 */
class SettingsEdit(
    /** The scene is sky and horizon; false is sky only. */
    val horizonDetection: Boolean,
    /** The camera moved during the sequence; false is fixed. */
    val cameraMoving: Boolean,
    val cleanMethod: CleanMethod,
    /** This machine has no GPU star can use (known only when the daemon says so). */
    val gpuUnavailable: Boolean = false,
    private val on: (String) -> Boolean = { false },
) {
    val skyOnly: Boolean get() = !horizonDetection
    val cameraFixed: Boolean get() = !cameraMoving

    /** Automatic finds no outlier groups to review, so what decides how strictly it looks for them applies to the other two methods. */
    val usesOutliers: Boolean get() = cleanMethod.usesOutliers

    /** The current value of the toggle with this id, edited or as the daemon sent it. */
    fun isOn(id: String): Boolean = on(id)
}
