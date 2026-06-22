package com.star.ui.theme

import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color

// Dark theme matching the macOS Star app's dark appearance.
private val StarDarkColorScheme = darkColorScheme(
    primary          = Color(0xFF90CAF9),   // light blue
    onPrimary        = Color(0xFF003258),
    primaryContainer = Color(0xFF00497A),
    secondary        = Color(0xFF9DC8E6),
    background       = Color(0xFF1A1A1A),
    surface          = Color(0xFF222222),
    surfaceVariant   = Color(0xFF2C2C2C),
    onBackground     = Color(0xFFE0E0E0),
    onSurface        = Color(0xFFE0E0E0),
    onSurfaceVariant = Color(0xFFBDBDBD),
    outline          = Color(0xFF555555),
    error            = Color(0xFFFF6B6B),
)

@Composable
fun StarTheme(content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = StarDarkColorScheme,
        content = content,
    )
}

// Named colors used across the UI.
object StarColors {
    val panelBackground = Color(0xFF1E1E1E)
    val panelBorder     = Color(0xFF3A3A3A)
    val filmstripBg     = Color(0xFF141414)
    val buttonBg        = Color(0xFF333333)
    val buttonHover     = Color(0xFF444444)
    val textPrimary     = Color(0xFFE0E0E0)
    val textSecondary   = Color(0xFFAAAAAA)

    // Outlier group box fill opacity (0.5 normally, 0.125 when selected)
    const val boxFillAlpha   = 0.5f
    const val boxSelectAlpha = 0.125f
    const val boxBorderAlpha = 0.33f
}
