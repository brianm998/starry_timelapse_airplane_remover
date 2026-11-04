package com.star.desktop.domain

import com.star.proto.CleanMethod

/**
 * Whether this clean method reviews outliers (macOS `CleanMethod.usesOutliers`). Plain automatic mode replaces
 * every bad pixel without per-frame review, so the editing tools have nothing to act on there; the dirty sky / dirty earth
 * methods don't review outliers either.
 */
val CleanMethod.usesOutliers: Boolean
    get() = this == CleanMethod.CLEAN_AUTOMATIC_TRUE || this == CleanMethod.CLEAN_SELECTIVE

/**
 * The tool to have selected after the session's clean method becomes [method]: the one that was, unless the new
 * method does not review outliers, when no tool applies (macOS `selectionMode = .none` in `applySettings`).
 */
fun toolAfterCleanMethodChange(tool: ToolType, method: CleanMethod): ToolType =
    if (method.usesOutliers) tool else ToolType.NONE

/**
 * The two questions behind a clean method as the macOS settings sheet asks them (`HighLevelCleanMethod` and `AutoPreservationMode`,
 * and `CleanMethod(highLevelCleanMethod:autoPreservationMode:)`): Automatic, Selective, Dirty sky or Dirty earth in the main column, and, among
 * the expert settings, whether Automatic keeps the signals it classifies ("Selective Auto Clean", which makes it auto-selective). The desktop
 * showed a single three-way choice; `gherkin/ui/vectors/constants.json` pins the mapping for both clients.
 */
enum class HighLevelClean {
    AUTOMATIC, SELECTIVE, DIRTY_SKY, DIRTY_EARTH;

    /** Only Automatic asks "Selective Auto Clean": Selective always uses outliers and the dirty methods never do (macOS `usesAutoPreservation`). */
    val usesAutoPreservation: Boolean get() = this == AUTOMATIC

    /** Dirty earth keeps only the ground, so it needs a horizon; every other choice is always there (macOS `isAvailable(horizonDetectionEnabled:)`). */
    fun isAvailable(horizonDetection: Boolean): Boolean = this != DIRTY_EARTH || horizonDetection

    /** What the choice becomes when the horizon is switched off: Dirty earth cannot stay chosen, so it falls back to Automatic (macOS `coerced`). */
    fun coerced(horizonDetection: Boolean): HighLevelClean = if (isAvailable(horizonDetection)) this else AUTOMATIC
}

object CleanMethodChoice {
    fun highLevel(method: CleanMethod): HighLevelClean = when (method) {
        CleanMethod.CLEAN_SELECTIVE -> HighLevelClean.SELECTIVE
        CleanMethod.CLEAN_DIRTY_SKY -> HighLevelClean.DIRTY_SKY
        CleanMethod.CLEAN_DIRTY_EARTH -> HighLevelClean.DIRTY_EARTH
        else -> HighLevelClean.AUTOMATIC
    }

    /** Where "Selective Auto Clean" starts when the sheet opens on [method]: Yes whenever the method reviews outliers (macOS `init`). */
    fun autoPreservationStart(method: CleanMethod): Boolean = method.usesOutliers

    /** The preservation answer is Automatic's alone; a dirty choice ignores it. */
    fun method(highLevel: HighLevelClean, autoPreservation: Boolean): CleanMethod = when (highLevel) {
        HighLevelClean.SELECTIVE -> CleanMethod.CLEAN_SELECTIVE
        HighLevelClean.DIRTY_SKY -> CleanMethod.CLEAN_DIRTY_SKY
        HighLevelClean.DIRTY_EARTH -> CleanMethod.CLEAN_DIRTY_EARTH
        HighLevelClean.AUTOMATIC -> if (autoPreservation) CleanMethod.CLEAN_AUTOMATIC_TRUE else CleanMethod.CLEAN_AUTOMATIC
    }
}

/**
 * The catalogue keys under the settings sheet's two clean-method rows, as the macOS sheet's `HighLevelCleanMethod` and `AutoPreservationMode`
 * read them (`gherkin/ui/vectors/constants.json`, `cleanMethod.texts`): a hover text on each choice and the paragraph under the row's (i).
 * The paragraphs were already the desktop's; the hover texts are the gui's, which were English paragraphs written in StarCore.
 */
object CleanMethodTexts {
    fun titleKey(choice: HighLevelClean): String = when (choice) {
        HighLevelClean.AUTOMATIC -> "ui.automatic"
        HighLevelClean.SELECTIVE -> "ui.selective"
        HighLevelClean.DIRTY_SKY -> "ui.dirty_sky"
        HighLevelClean.DIRTY_EARTH -> "ui.dirty_earth"
    }

    fun tipKey(choice: HighLevelClean): String = when (choice) {
        HighLevelClean.AUTOMATIC -> "ui.clean_method_tip.automatic"
        HighLevelClean.SELECTIVE -> "ui.clean_method_tip.selective"
        HighLevelClean.DIRTY_SKY -> "ui.clean_method_tip.dirty_sky"
        HighLevelClean.DIRTY_EARTH -> "ui.clean_method_tip.dirty_earth"
    }

    /** The tip a switched-off choice shows instead of its own, or null while it is on. */
    fun unavailableTipKey(choice: HighLevelClean, horizonDetection: Boolean): String? =
        if (choice.isAvailable(horizonDetection)) null else "ui.clean_method_tip.dirty_earth_needs_horizon"

    fun descriptionKey(choice: HighLevelClean): String = when (choice) {
        HighLevelClean.AUTOMATIC -> "ui.mode_desc_automatic"
        HighLevelClean.SELECTIVE -> "ui.mode_desc_selective"
        HighLevelClean.DIRTY_SKY -> "ui.mode_desc_dirty_sky"
        HighLevelClean.DIRTY_EARTH -> "ui.mode_desc_dirty_earth"
    }

    fun autoPreservationTipKey(yes: Boolean): String = if (yes) "ui.selective_auto_clean_tip.yes" else "ui.selective_auto_clean_tip.no"

    fun autoPreservationDescriptionKey(yes: Boolean): String = if (yes) "ui.mode_desc_auto_selective" else "ui.mode_desc_automatic"
}
