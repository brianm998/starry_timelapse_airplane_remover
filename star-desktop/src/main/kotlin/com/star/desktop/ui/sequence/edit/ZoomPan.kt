package com.star.desktop.ui.sequence.edit

import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.PointerEventType
import androidx.compose.ui.input.pointer.PointerType
import androidx.compose.ui.input.pointer.isAltPressed
import androidx.compose.ui.input.pointer.isCtrlPressed
import androidx.compose.ui.input.pointer.isMetaPressed
import androidx.compose.ui.input.pointer.isShiftPressed
import androidx.compose.ui.input.pointer.isTertiaryPressed
import androidx.compose.ui.input.pointer.onPointerEvent
import androidx.compose.ui.input.pointer.pointerInput

/**
 * Zooming and panning of a [FrameTransform], the same for every view that shows the frame (the edit view and the horizon
 * painter), and for every tool in them:
 *  - the mouse wheel / two-finger scroll **pans** (Shift turns vertical scrolling into horizontal);
 *  - Ctrl (or Cmd) with the wheel **zooms** around the pointer;
 *  - dragging with the **middle** mouse button, or with **Alt/Option** held, pans.
 *
 * (Space-drag would be the third way, but Space is the play/pause accelerator of the menu, which Compose delivers
 * before it reaches the view; a trackpad has the scroll and Alt-drag instead.)
 *
 * The drag is watched on the Initial pass and consumed there, so whatever tool is drawing or selecting in the same view
 * never sees it as a stroke or a box.
 */
@OptIn(ExperimentalComposeUiApi::class)
fun Modifier.zoomAndPan(transform: FrameTransform, canvasSize: () -> Size): Modifier = this
    .onPointerEvent(PointerEventType.Scroll) { ev ->
        val change = ev.changes.firstOrNull() ?: return@onPointerEvent
        val d = change.scrollDelta
        val canvas = canvasSize()
        if (ev.keyboardModifiers.isCtrlPressed || ev.keyboardModifiers.isMetaPressed) {
            if (d.y != 0f) {
                transform.zoomBy(FrameTransform.zoomFactor(d.y), change.position, canvas)
                change.consume()
            }
        } else if (d.x != 0f || d.y != 0f) {
            val shifted = ev.keyboardModifiers.isShiftPressed
            val along = if (shifted) Offset(d.y, d.x) else d
            // Scrolling down moves the picture up, like any scrolled content.
            transform.panBy(Offset(-along.x, -along.y) * FrameTransform.SCROLL_PAN_STEP, canvas)
            change.consume()
        }
    }
    .pointerInput(transform) {
        awaitEachGesture {
            val down = awaitFirstDown(requireUnconsumed = false, pass = PointerEventPass.Initial)
            val buttons = currentEvent.buttons
            val modifiers = currentEvent.keyboardModifiers
            val panning = down.type == PointerType.Mouse && (buttons.isTertiaryPressed || modifiers.isAltPressed)
            if (!panning) return@awaitEachGesture
            down.consume()
            while (true) {
                val event = awaitPointerEvent(PointerEventPass.Initial)
                val change = event.changes.firstOrNull { it.id == down.id } ?: break
                if (!change.pressed) {
                    change.consume()
                    break
                }
                val delta = change.position - change.previousPosition
                if (FrameTransform.isMovement(delta)) transform.panBy(delta, canvasSize())
                change.consume()
            }
        }
    }
