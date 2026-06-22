package com.star.ui

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.*
import androidx.compose.foundation.layout.*
import androidx.compose.runtime.*
import androidx.compose.ui.*
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.*
import androidx.compose.ui.input.pointer.*
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.unit.*
import com.star.viewmodel.FrameViewModel
import com.star.viewmodel.ToolType

/**
 * Frame display with zoom/pan and outlier overlay.
 * Mirrors FrameView.swift + FrameEditView.swift + FrameImageView.swift.
 *
 * Zoom/pan via scroll (zoom) + drag (pan) — mirrors the Zoomable SwiftUI views.
 * Outlier overlay hit-testing uses the label image loaded by FrameViewModel.
 */
@Composable
fun FrameView(
    frameViewModel: FrameViewModel,
    activeTool: ToolType,
) {
    val preview by frameViewModel.preview.collectAsState()
    val outlierGroups by frameViewModel.outlierGroups.collectAsState()
    val labelImage by frameViewModel.labelImage.collectAsState()

    var zoom by remember { mutableStateOf(1f) }
    var offsetX by remember { mutableStateOf(0f) }
    var offsetY by remember { mutableStateOf(0f) }

    // Track actual rendered image size for coordinate mapping.
    var imageSize by remember { mutableStateOf(IntSize.Zero) }

    Box(
        Modifier
            .fillMaxSize()
            .background(Color(0xFF0D0D0D))
            .pointerInput(Unit) {
                // Scroll to zoom
                detectTransformGestures { centroid, pan, zoomChange, _ ->
                    val newZoom = (zoom * zoomChange).coerceIn(0.1f, 20f)
                    // Zoom around the centroid
                    val scale = newZoom / zoom
                    offsetX = centroid.x - scale * (centroid.x - offsetX) + pan.x
                    offsetY = centroid.y - scale * (centroid.y - offsetY) + pan.y
                    zoom = newZoom
                }
            }
            .pointerInput(activeTool, labelImage) {
                // Click to toggle outlier group decision
                detectTapGestures { tapOffset ->
                    val label = labelImage ?: return@detectTapGestures
                    // Map screen coords to image coords
                    val imgX = ((tapOffset.x - offsetX) / zoom).toInt()
                    val imgY = ((tapOffset.y - offsetY) / zoom).toInt()
                    frameViewModel.hitTest(imgX, imgY, activeTool)
                }
            },
    ) {
        preview?.let { bmp ->
            Image(
                bitmap = bmp,
                contentDescription = "Frame",
                modifier = Modifier
                    .graphicsLayer(
                        scaleX = zoom,
                        scaleY = zoom,
                        translationX = offsetX,
                        translationY = offsetY,
                        transformOrigin = TransformOrigin(0f, 0f),
                    )
                    .onSizeChanged { size ->
                        imageSize = size
                    },
                contentScale = androidx.compose.ui.layout.ContentScale.None,
            )
        }

        // Outlier overlay: drawn in a Canvas on top of the image, using the same transform.
        if (outlierGroups.isNotEmpty()) {
            OutlierOverlay(
                groups = outlierGroups,
                zoom = zoom,
                offsetX = offsetX,
                offsetY = offsetY,
                modifier = Modifier.fillMaxSize(),
            )
        }
    }
}
