package com.star.desktop.ui.components

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Icon
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.scale
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.painter.Painter
import androidx.compose.ui.unit.dp
import com.star.desktop.ui.theme.StarColors

/**
 * macOS `ShrinkingButton`: a borderless clickable that shrinks slightly while pressed and dims when
 * disabled. Used for the panel/toolbar action buttons.
 */
@Composable
fun ShrinkingButton(
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    content: @Composable () -> Unit,
) {
    val interaction = remember { MutableInteractionSource() }
    val pressed by interaction.collectIsPressedAsState()
    val scale by animateFloatAsState(if (pressed && enabled) 0.9f else 1f, label = "shrink")
    Surface(
        onClick = onClick,
        enabled = enabled,
        interactionSource = interaction,
        color = Color.Transparent,
        shape = CircleShape, // macOS ShrinkingButton clips to a capsule
        modifier = modifier.scale(scale).alpha(if (enabled) 1f else 0.4f),
    ) {
        content()
    }
}

/**
 * macOS `SystemButton`: an icon button (default 30pt icon). Optional label to its right.
 */
@Composable
fun SystemButton(
    painter: Painter,
    contentDescription: String?,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    iconSize: Int = 30,
    tint: Color = LocalContentColor.current,
    label: String? = null,
) {
    ShrinkingButton(onClick = onClick, enabled = enabled, modifier = modifier) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(6.dp),
            modifier = Modifier.padding(4.dp),
        ) {
            Icon(painter = painter, contentDescription = contentDescription, tint = tint, modifier = Modifier.size(iconSize.dp))
            if (label != null) Text(label, color = StarColors.textPrimary)
        }
    }
}
