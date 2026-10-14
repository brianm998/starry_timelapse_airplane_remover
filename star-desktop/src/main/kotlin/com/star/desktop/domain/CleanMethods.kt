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
