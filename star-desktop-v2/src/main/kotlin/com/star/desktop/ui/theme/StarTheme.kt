package com.star.desktop.ui.theme

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable

private val DarkColors = darkColorScheme(
    primary = StarColors.accent,
    onPrimary = StarColors.white,
    background = StarColors.appBackground,
    onBackground = StarColors.textPrimary,
    surface = StarColors.sidePanel,
    onSurface = StarColors.textPrimary,
    surfaceVariant = StarColors.prefsCard,
    onSurfaceVariant = StarColors.textSecondary,
    error = StarColors.red,
)

/** Root theme: dark only, matching the macOS app (which has no light theme). */
@Composable
fun StarTheme(content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = DarkColors,
        content = content,
    )
}
