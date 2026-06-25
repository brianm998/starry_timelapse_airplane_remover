package com.star.desktop.ui.theme

import androidx.compose.material3.Typography
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp

/**
 * The macOS SwiftUI semantic type scale (AppKit sizes, NOT the larger iOS values): largeTitle 26,
 * title 22, title2 17, title3 15, headline/body 13, caption 10–11. Use these named styles instead of
 * ad-hoc `fontSize =` so headings stay consistent and match the Swift app.
 */
object StarType {
    val largeTitle = TextStyle(fontSize = 26.sp, fontWeight = FontWeight.Normal)
    val title = TextStyle(fontSize = 22.sp, fontWeight = FontWeight.Normal)
    val title2 = TextStyle(fontSize = 17.sp, fontWeight = FontWeight.Normal)
    val title3 = TextStyle(fontSize = 15.sp, fontWeight = FontWeight.Normal)
    val headline = TextStyle(fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
    val body = TextStyle(fontSize = 13.sp, fontWeight = FontWeight.Normal)
    val caption = TextStyle(fontSize = 11.sp, fontWeight = FontWeight.Normal)
    val caption2 = TextStyle(fontSize = 10.sp, fontWeight = FontWeight.Normal)
    val monoCaption = caption.copy(fontFamily = FontFamily.Monospace)
}

/**
 * Material role → macOS size mapping. Only affects components that don't set their own size (e.g.
 * Material Button/OutlinedButton labels); the app's explicit `fontSize`/`style` Text calls win.
 */
val StarTypography = Typography(
    titleLarge = StarType.title,
    titleMedium = StarType.title2,
    titleSmall = StarType.title3,
    headlineSmall = StarType.largeTitle,
    bodyLarge = StarType.body,
    bodyMedium = StarType.body,
    bodySmall = StarType.caption,
    labelLarge = StarType.body.copy(fontWeight = FontWeight.Medium), // default Button text keeps emphasis
    labelMedium = StarType.caption,
    labelSmall = StarType.caption2,
)
