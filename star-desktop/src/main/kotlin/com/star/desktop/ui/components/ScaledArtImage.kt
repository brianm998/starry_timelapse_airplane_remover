package com.star.desktop.ui.components

import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.unit.Dp

/** A piece of art drawn at a given [height], keeping its aspect. Decoration: no content description, no strings. */
@Composable
fun ScaledArtImage(art: StarArt, height: Dp, modifier: Modifier = Modifier) {
    Image(
        painter = painterResource(art.resourcePath),
        contentDescription = null,
        contentScale = ContentScale.Fit,
        modifier = modifier.height(height).aspectRatio(art.width.toFloat() / art.height.toFloat()),
    )
}
