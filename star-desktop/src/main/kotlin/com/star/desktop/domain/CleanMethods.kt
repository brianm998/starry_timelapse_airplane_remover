package com.star.desktop.domain

import com.star.proto.CleanMethod

/**
 * Whether this clean method reviews outliers (macOS `CleanMethod.usesOutliers`). Plain automatic mode replaces
 * every bad pixel without per-frame review, so the editing tools have nothing to act on there.
 */
val CleanMethod.usesOutliers: Boolean get() = this != CleanMethod.CLEAN_AUTOMATIC

/**
 * The tool to have selected after the session's clean method becomes [method]: the one that was, unless the new
 * method does not review outliers, when no tool applies (macOS `selectionMode = .none` in `applySettings`).
 */
fun toolAfterCleanMethodChange(tool: ToolType, method: CleanMethod): ToolType =
    if (method.usesOutliers) tool else ToolType.NONE

/**
 * The two questions behind a clean method as the macOS settings sheet asks them (`HighLevelCleanMethod` and `AutoPreservationMode`,
 * and `CleanMethod(highLevelCleanMethod:autoPreservationMode:)`): Automatic or Selective in the main column, and, among the expert
 * settings, whether Automatic keeps the signals it classifies ("Selective Auto Clean", which makes it auto-selective). The desktop
 * showed a single three-way choice; `gherkin/ui/vectors/constants.json` pins the mapping for both clients.
 */
enum class HighLevelClean { AUTOMATIC, SELECTIVE }

object CleanMethodChoice {
    fun highLevel(method: CleanMethod): HighLevelClean =
        if (method == CleanMethod.CLEAN_SELECTIVE) HighLevelClean.SELECTIVE else HighLevelClean.AUTOMATIC

    /** Where "Selective Auto Clean" starts when the sheet opens on [method]: Yes whenever the method reviews outliers (macOS `init`). */
    fun autoPreservationStart(method: CleanMethod): Boolean = method.usesOutliers

    fun method(highLevel: HighLevelClean, autoPreservation: Boolean): CleanMethod = when (highLevel) {
        HighLevelClean.SELECTIVE -> CleanMethod.CLEAN_SELECTIVE
        HighLevelClean.AUTOMATIC -> if (autoPreservation) CleanMethod.CLEAN_AUTOMATIC_TRUE else CleanMethod.CLEAN_AUTOMATIC
    }
}
