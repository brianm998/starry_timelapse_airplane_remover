package com.star.desktop.ui.components

import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.painter.Painter
import androidx.compose.ui.res.painterResource
import com.star.desktop.domain.ToolType

/** Painter for a tool's PNG icon (re-exported from the macOS asset catalog into `resources/icons/`). */
@Composable
fun toolPainter(tool: ToolType): Painter = painterResource("icons/${tool.iconBaseName}.png")

/** Painter for a named icon resource under `resources/icons/`. */
@Composable
fun iconPainter(baseName: String): Painter = painterResource("icons/$baseName.png")
