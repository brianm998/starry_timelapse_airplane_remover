package com.star.desktop.ui.theme

import androidx.compose.ui.graphics.Color
import com.star.desktop.domain.OutlierDecisions
import com.star.desktop.domain.ToolType
import com.star.proto.RemoveReason

/**
 * The macOS app's dark palette, recovered from source (`ViewModel.defaultBackgroundColor`,
 * `LeftPanel`/`RightPanel`, `GridLeftPanel`, `StarPicker`, `OutlierGroupViewModel`, filmstrip cells).
 *
 * Semantic hues mirror SwiftUI's system named colors (`.red/.green/.orange/.blue/...`) — the macOS
 * app uses those directly — approximated here with Apple's sRGB system values so the look matches.
 */
object StarColors {
    // ---- chrome / surfaces ----
    val appBackground = Color(0.10f, 0.10f, 0.10f)          // #1A1A1A
    val playbackBackground = Color.Black
    val sidePanel = Color(0.22f, 0.22f, 0.22f)              // ≈ #383838
    val gridLeftPanel = Color(0.18f, 0.18f, 0.18f)          // ≈ #2E2E2E
    val prefsHeader = Color(0.15f, 0.15f, 0.15f)            // #262626
    val prefsCard = Color(0.12f, 0.12f, 0.12f)              // #1F1F1F
    val prefsInfoBox = Color(0.20f, 0.20f, 0.20f)           // #333333
    val pickerTrack = Color(134 / 255f, 134 / 255f, 138 / 255f) // #86868A
    val scrim = Color(0f, 0f, 0f, 0.5f)

    // ---- filmstrip / grid cell tiers ----
    val cellHighlighted = Color(0.52f, 0.52f, 0.52f)        // current frame
    val cellSelected = Color(0.38f, 0.38f, 0.38f)           // in multi-selection
    val cellDefault = Color(0.22f, 0.22f, 0.22f)

    // ---- text ----
    val textPrimary = Color(0.92f, 0.92f, 0.92f)
    val textSecondary = Color(0.62f, 0.62f, 0.62f)
    val textDisabled = Color(0.40f, 0.40f, 0.40f)

    // ---- Apple system semantic hues ----
    val red = Color(1.00f, 0.231f, 0.188f)
    val green = Color(0.204f, 0.780f, 0.349f)
    val orange = Color(1.00f, 0.584f, 0.0f)
    val blue = Color(0.0f, 0.478f, 1.0f)
    val yellow = Color(1.0f, 0.80f, 0.0f)
    val purple = Color(0.686f, 0.322f, 0.871f)
    val pink = Color(1.0f, 0.176f, 0.333f)
    val mint = Color(0.0f, 0.78f, 0.745f)
    val gray = Color(0.557f, 0.557f, 0.576f)
    val white = Color.White
    val accent = blue

    /** Per-tool selection color (macOS `ToolType` highlight colors). */
    fun toolColor(tool: ToolType): Color = when (tool) {
        ToolType.REMOVE -> red
        ToolType.KEEP -> green
        ToolType.RAZOR -> yellow
        ToolType.SHOVEL -> gray
        ToolType.TRASH -> pink
        ToolType.REMOVE_FROM_TRASH -> mint
        ToolType.MULTI -> purple
        ToolType.INFORMATION -> blue
        ToolType.NONE -> Color.Black
    }

    /**
     * Outlier group box color (macOS `OutlierGroupViewModel.groupColor`):
     * selected → orange; will-remove → red; will-keep → green; undecided → blue.
     */
    fun groupColor(reason: RemoveReason, selected: Boolean): Color = when {
        selected -> orange
        reason == RemoveReason.RR_USER_REMOVE || reason == RemoveReason.RR_CLASSIFIER_REMOVE -> red
        reason == RemoveReason.RR_USER_KEEP || reason == RemoveReason.RR_CLASSIFIER_KEEP -> green
        else -> blue
    }

    /**
     * Direction-arrow & guide-line color (macOS `OutlierGroupViewModel.arrowColor`): selected → blue;
     * decided & hovered → red/green by decision; decided & idle → white; undecided & hovered → red;
     * undecided & idle → blue. (Distinct from [groupColor], which the box uses.)
     */
    fun arrowColor(reason: RemoveReason, selected: Boolean, hovered: Boolean): Color {
        val willRemove = OutlierDecisions.willRemove(reason)
        return when {
            selected -> blue
            willRemove != null -> if (hovered) (if (willRemove) red else green) else white
            else -> if (hovered) red else blue
        }
    }
}
