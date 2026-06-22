package com.star.viewmodel

import androidx.compose.ui.graphics.Color
import com.star.proto.OutlierGroup
import com.star.proto.RemoveReason

/**
 * UI state for a single outlier group.
 * Colors mirror OutlierGroupViewModel.swift (groupColor / arrowColor).
 */
data class OutlierGroupState(
    val id: Int,                      // uint32 group id
    val bounds: GroupBounds,
    val size: Long,
    val brightness: Long,
    val classificationScore: Double,
    val line: LineInfo?,
    var decision: RemoveReason = RemoveReason.RR_UNDECIDED,
    var isSelected: Boolean = false,
    var arrowSelected: Boolean = false,
) {
    /** Box color per OutlierGroupViewModel.swift groupColor. */
    val groupColor: Color
        get() = when {
            isSelected -> Color(0xFF, 0xA5, 0x00)    // orange
            decision.willRemove == true -> Color.Red
            decision.willRemove == false -> Color.Green
            else -> Color.Blue
        }

    /** Arrow/direction-indicator color per OutlierGroupViewModel.swift arrowColor. */
    val arrowColor: Color
        get() = when {
            isSelected -> Color.Blue
            decision.willRemove != null && arrowSelected ->
                if (decision.willRemove == true) Color.Red else Color.Green
            decision.willRemove != null -> Color.White
            arrowSelected -> Color.Red
            else -> Color.Blue
        }

    companion object {
        fun from(group: OutlierGroup) = OutlierGroupState(
            id = group.id.toInt(),
            bounds = GroupBounds(group.bounds.minX, group.bounds.minY, group.bounds.maxX, group.bounds.maxY),
            size = group.size.toLong(),
            brightness = group.brightness.toLong(),
            classificationScore = group.classificationScore,
            line = if (group.hasLine()) LineInfo(group.line.theta, group.line.rho, group.line.votes) else null,
            decision = group.shouldRemove,
        )
    }
}

data class GroupBounds(val minX: Int, val minY: Int, val maxX: Int, val maxY: Int) {
    val width: Int get() = maxX - minX
    val height: Int get() = maxY - minY
}

data class LineInfo(val theta: Double, val rho: Double, val votes: Int)

val RemoveReason.willRemove: Boolean?
    get() = when (this) {
        RemoveReason.RR_USER_REMOVE, RemoveReason.RR_CLASSIFIER_REMOVE -> true
        RemoveReason.RR_USER_KEEP, RemoveReason.RR_CLASSIFIER_KEEP -> false
        else -> null
    }
