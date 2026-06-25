package com.star.desktop.ui.sequence.edit

import androidx.compose.ui.input.pointer.PointerIcon
import com.star.desktop.domain.ToolType
import com.star.desktop.util.Log
import java.awt.Point
import java.awt.Toolkit
import java.util.concurrent.ConcurrentHashMap
import javax.imageio.ImageIO
import kotlin.math.roundToInt

/**
 * Tool-dependent frame cursors (macOS `CursorView`): a crosshair while hovering the frame, a
 * pointing variant while dragging or hovering an outlier group. Each tool's PNGs live at
 * `icons/<base>_crosshair.png` / `_pointing.png`. SF Symbols are not involved — these are bundled
 * assets. Built once per (base, variant) as an AWT custom cursor wrapped in a Compose [PointerIcon].
 */
object ToolCursors {
    // Hotspots as fractions of the cursor size (macOS: crosshair (15,15)/40, pointing (9,5.67)/40).
    private const val CROSSHAIR_HOT = 15f / 40f
    private const val POINTING_HOT_X = 9f / 40f
    private const val POINTING_HOT_Y = 5.667f / 40f

    private val cache = ConcurrentHashMap<String, PointerIcon>()

    fun crosshair(tool: ToolType): PointerIcon =
        tool.cursorBaseName?.let { byBase(it, "crosshair", CROSSHAIR_HOT, CROSSHAIR_HOT) } ?: PointerIcon.Default

    fun pointing(tool: ToolType): PointerIcon =
        tool.cursorBaseName?.let { byBase(it, "pointing", POINTING_HOT_X, POINTING_HOT_Y) } ?: PointerIcon.Default

    /** Cursor while hovering a group (macOS OutlierGroupView.currentCursor): reflects the click action. */
    fun groupPointing(tool: ToolType, willRemove: Boolean?): PointerIcon {
        val base = when (tool) {
            ToolType.NONE -> return PointerIcon.Default
            ToolType.TRASH -> "delete_trash"
            ToolType.INFORMATION -> "info"
            else -> if (willRemove == true) "keep" else "remove"
        }
        return byBase(base, "pointing", POINTING_HOT_X, POINTING_HOT_Y)
    }

    private fun byBase(base: String, variant: String, hotXFrac: Float, hotYFrac: Float): PointerIcon {
        val key = "${base}_$variant"
        cache[key]?.let { return it }
        val icon = build(key, hotXFrac, hotYFrac) ?: PointerIcon.Default
        cache[key] = icon
        return icon
    }

    private fun build(name: String, hotXFrac: Float, hotYFrac: Float): PointerIcon? = try {
        val stream = ToolCursors::class.java.getResourceAsStream("/icons/$name.png") ?: return null
        val img = stream.use { ImageIO.read(it) } ?: return null
        val tk = Toolkit.getDefaultToolkit()
        val best = tk.getBestCursorSize(img.width, img.height)
        val w = if (best.width > 0) best.width else img.width
        val h = if (best.height > 0) best.height else img.height
        val hot = Point(
            (hotXFrac * w).roundToInt().coerceIn(0, w - 1),
            (hotYFrac * h).roundToInt().coerceIn(0, h - 1),
        )
        PointerIcon(tk.createCustomCursor(img, hot, name)) // AWT scales the image to the best cursor size
    } catch (e: Exception) {
        Log.w("ToolCursors") { "failed to build cursor $name: ${e.message}" }
        null
    }
}
