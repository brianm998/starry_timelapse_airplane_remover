package com.star.desktop.ui.components

import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.widthIn
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.unit.dp

/** The waiting robot over an empty window's lines. It shrinks in a small window rather than being clipped. */
@Composable
fun WaitingArt(modifier: Modifier = Modifier) {
    val art = StarArt.ART_WAITING
    Image(
        painter = painterResource(art.resourcePath),
        contentDescription = null,
        modifier = modifier.widthIn(max = art.width.dp).aspectRatio(art.width.toFloat() / art.height),
    )
}
