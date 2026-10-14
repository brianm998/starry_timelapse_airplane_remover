package com.star.desktop.domain

import com.star.proto.Line
import com.star.proto.LineCandidate
import kotlin.math.abs

/** The outlier window's table of the lines the Hough finder proposes for a group (macOS `HoughLinesTableView`). */
object HoughLines {
    enum class Column { INTENSITY, PIXEL, THETA, RHO, VOTES, BORDER }

    private fun value(c: LineCandidate, column: Column): Double = when (column) {
        Column.INTENSITY -> c.intensityScore
        Column.PIXEL -> c.pixelScore
        Column.THETA -> c.line.theta
        Column.RHO -> c.line.rho
        Column.VOTES -> c.line.votes.toDouble()
        Column.BORDER -> c.border.toDouble()
    }

    data class Sort(val column: Column, val ascending: Boolean)

    /** Best fit first, which is the order the daemon sends them in. */
    val defaultSort = Sort(Column.INTENSITY, ascending = false)

    /** What clicking [column]'s header does: the same column turns the order round, another sorts by it, smallest first. */
    fun clicked(current: Sort, column: Column): Sort =
        if (current.column == column) current.copy(ascending = !current.ascending) else Sort(column, ascending = true)

    fun sorted(candidates: List<LineCandidate>, sort: Sort): List<LineCandidate> {
        val ordered = compareBy<LineCandidate> { value(it, sort.column) }
        return candidates.sortedWith(if (sort.ascending) ordered else ordered.reversed())
    }

    /** Whether [candidate] is [line], the one a group has now (the finder gives a group its own line, which is one of its candidates). */
    fun isLine(candidate: LineCandidate, line: Line?): Boolean =
        line != null && abs(candidate.line.theta - line.theta) < 1e-6 && abs(candidate.line.rho - line.rho) < 1e-6

    /** A score, angle or distance as the table shows it (macOS `%.2f`). */
    fun format(v: Double): String = String.format(java.util.Locale.ROOT, "%.2f", v)
}
