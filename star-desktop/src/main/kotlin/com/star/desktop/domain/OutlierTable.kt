package com.star.desktop.domain

import com.star.proto.RemoveReason
import java.math.BigDecimal
import java.math.MathContext
import java.math.RoundingMode
import kotlin.math.abs

/**
 * The outlier window's table (macOS `OutlierGroupTable`): which columns it can show, how its rows sort, which of them a click selects,
 * and how a feature value is written. The values themselves come from the daemon (`Outlier.GetFeatures`).
 */
object OutlierTable {
    /** Where a column's value comes from. */
    enum class Source { ID, FEATURE, CLASSIFICATION }

    /**
     * An optional column. [key] is what is remembered about it; [feature] is the daemon's name for the value (`OutlierGroupFeature`,
     * for [Source.FEATURE] columns); [labelKey] is its name in the catalogue.
     */
    data class Column(val key: String, val source: Source, val feature: String, val labelKey: String, val defaultVisible: Boolean)

    private fun feature(name: String, visible: Boolean = true) = Column(name, Source.FEATURE, name, "ui.${name.lowercase()}", visible)

    /** The optional columns, in the order the table shows them; the decision and the size are always there. macOS's defaults: which are on. */
    val columns: List<Column> = listOf(
        Column("name", Source.ID, "name", "ui.name", defaultVisible = false),
        feature("width"), feature("height"),
        feature("centerX", visible = false), feature("centerY", visible = false),
        feature("minX", visible = false), feature("minY", visible = false), feature("maxX", visible = false), feature("maxY", visible = false),
        feature("hypotenuse"), feature("aspectRatio"), feature("fillAmount"), feature("surfaceAreaRatio"),
        feature("averagebrightness"), feature("medianBrightness"), feature("maxBrightness"),
        feature("numberOfNearbyOutliersInSameFrame"), feature("maxHoughTransformCount"), feature("pixelBorderAmount"),
        feature("averageLineVariance"), feature("lineLength"),
        feature("nearbyDirectOverlapScore"), feature("boundingBoxOverlapScore"), feature("lineIntensityScore"), feature("linePixelScore"),
        feature("borderBrightness"), feature("bunchCount"), feature("medianBunchSize"), feature("maxBunchSize"),
        feature("neighborLineThetaScore"), feature("neighborLineRhoScore"), feature("neighborLineSizeScore"),
        feature("neighborLineBrightnessScore"), feature("neighborLineDistanceScore"),
        Column("classificationScore", Source.CLASSIFICATION, "classification", "ui.classification_score", defaultVisible = true),
    )

    /** The keys of the columns that show until the user chooses otherwise. */
    val defaultColumns: Set<String> = columns.filter { it.defaultVisible }.map { it.key }.toSet()

    /** The columns to show for a remembered choice of keys (null: never chosen), in table order; keys that are no longer columns are ignored. */
    fun visible(chosen: Collection<String>?): List<Column> {
        val keys = chosen?.toSet() ?: defaultColumns
        return columns.filter { it.key in keys }
    }

    /** One group's line in the table. */
    data class Row(val groupId: Int, val size: Long, val features: Map<String, Double>, val classification: Double)

    /** [row]'s value for [column]. */
    fun value(row: Row, column: Column): Double = when (column.source) {
        Source.ID -> row.groupId.toDouble()
        Source.FEATURE -> row.features[column.feature] ?: 0.0
        Source.CLASSIFICATION -> row.classification
    }

    // ---- sorting ----

    /** The always-shown columns, which sort as well. */
    const val DECISION = "remove"
    const val SIZE = "size"

    /** Which column the rows are in the order of, and which way. */
    data class Sort(val key: String, val ascending: Boolean)

    /** Largest first, as macOS lists the groups it opens the window with. */
    val defaultSort = Sort(SIZE, ascending = false)

    /** What clicking [key]'s header does: the same column turns the order round, another column sorts by it, smallest first. */
    fun clicked(current: Sort, key: String): Sort = if (current.key == key) current.copy(ascending = !current.ascending) else Sort(key, ascending = true)

    /** The place a decision has when sorting (macOS `WillRemoveType`: to be removed, then kept, then undecided). */
    fun decisionRank(reason: RemoveReason): Int = when (OutlierDecisions.willRemove(reason)) {
        true -> 0
        false -> 1
        null -> 2
    }

    /** [rows] in the order of [sort]; rows that tie keep the order of their group ids. */
    fun sorted(rows: List<Row>, sort: Sort, decisionOf: (Int) -> RemoveReason): List<Row> {
        val column = columns.firstOrNull { it.key == sort.key }
        val primary: Comparator<Row> = when {
            sort.key == DECISION -> compareBy { decisionRank(decisionOf(it.groupId)) }
            sort.key == SIZE -> compareBy { it.size }
            column != null -> compareBy { value(it, column) }
            else -> compareBy { it.size }
        }
        val ordered = if (sort.ascending) primary else primary.reversed()
        return rows.sortedWith(ordered.thenBy { it.groupId })
    }

    // ---- selecting rows ----

    /** The selected groups, and the one a shift-click extends from. */
    data class Selection(val ids: Set<Int> = emptySet(), val anchor: Int? = null)

    /**
     * What a click on [clicked] does to the selection of a table whose rows are [ordered] top to bottom: a plain click selects that row
     * alone; [toggle] (Ctrl/Cmd) adds it or takes it out; [extend] (Shift) selects everything from the last clicked row to this one.
     */
    fun click(current: Selection, ordered: List<Int>, clicked: Int, toggle: Boolean, extend: Boolean): Selection {
        val anchor = current.anchor
        if (extend && anchor != null && anchor in ordered && clicked in ordered) {
            val from = ordered.indexOf(anchor)
            val to = ordered.indexOf(clicked)
            val range = ordered.subList(minOf(from, to), maxOf(from, to) + 1).toSet()
            return Selection(if (toggle) current.ids + range else range, anchor)
        }
        return when {
            toggle -> Selection(if (clicked in current.ids) current.ids - clicked else current.ids + clicked, clicked)
            else -> Selection(setOf(clicked), clicked)
        }
    }

    // ---- values ----

    /**
     * [value] with [digits] significant digits, as C's `%g` (macOS shows `String(format: "%.5g")`): no trailing zeros, and an exponent
     * for very small and very large numbers.
     */
    fun formatG(value: Double, digits: Int = 5): String {
        if (value.isNaN()) return "nan"
        if (value.isInfinite()) return if (value > 0) "inf" else "-inf"
        if (value == 0.0) return "0"
        val rounded = BigDecimal(value).round(MathContext(digits, RoundingMode.HALF_EVEN))
        val exponent = rounded.precision() - rounded.scale() - 1
        if (exponent < -4 || exponent >= digits) {
            val significant = rounded.unscaledValue().abs().toString().trimEnd('0').ifEmpty { "0" }
            val mantissa = if (significant.length > 1) "${significant[0]}.${significant.substring(1)}" else significant
            val sign = if (rounded.signum() < 0) "-" else ""
            val exp = (if (exponent < 0) "-" else "+") + abs(exponent).toString().padStart(2, '0')
            return "$sign${mantissa}e$exp"
        }
        return rounded.stripTrailingZeros().toPlainString()
    }
}
