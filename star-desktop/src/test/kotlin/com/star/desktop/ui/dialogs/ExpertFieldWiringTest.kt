package com.star.desktop.ui.dialogs

import com.star.proto.Config
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * Each ExpertField carries three lambdas — get, set and has — hand-paired to one proto
 * field. Nothing in the type system ties them together, so a new field can be given a
 * predicate belonging to a different one, and the symptom is silent: the row would report
 * "needs a newer engine" against a daemon that supports it perfectly well, or worse, offer
 * to edit a field whose value it is reading from somewhere else.
 *
 * The pairing is not introspectable — the lambdas are opaque and protobuf-lite has no
 * descriptors — but it is observable. Write through `set` and both `has` and `get` have to
 * agree, on a config where that field is the only one touched. If any of the three points
 * at a different field, these fail.
 */
class ExpertFieldWiringTest {

    private val allFields: List<ExpertField> = ALIGNMENT_FIELDS + HORIZON_FIELDS + MEMORY_FIELDS

    @Test
    fun everyFieldIsAbsentOnAnEmptyConfig() {
        val empty = Config.getDefaultInstance()
        for (f in allFields) {
            assertFalse(
                f.has(empty),
                "${f.label}: reports present on an empty config, so the dialog would render " +
                    "its proto3 default as if the daemon had sent it",
            )
        }
    }

    @Test
    fun writingAFieldMakesItsOwnPredicateTrue() {
        for (f in allFields) {
            val cfg = writeOnly(f)
            assertTrue(
                f.has(cfg),
                "${f.label}: set() wrote the field but has() still reports absent — the " +
                    "predicate belongs to a different field",
            )
        }
    }

    @Test
    fun writingAFieldIsWhatItsGetterReadsBack() {
        for (f in allFields) {
            val cfg = writeOnly(f)
            when (f) {
                is IntField -> assertEquals(
                    intProbe(f), f.get(cfg),
                    "${f.label}: getter did not read back what the setter wrote",
                )
                is DoubleField -> assertEquals(
                    DOUBLE_PROBE, f.get(cfg), 0.0,
                    "${f.label}: getter did not read back what the setter wrote",
                )
                is BoolField -> assertTrue(
                    f.get(cfg),
                    "${f.label}: getter did not read back what the setter wrote",
                )
            }
        }
    }

    /**
     * The strong form: writing one field must not make any OTHER field's predicate true.
     * Two fields sharing a predicate passes the per-field checks above — both would be
     * present because both were written in their own pass — and only shows up here.
     */
    @Test
    fun writingAFieldMakesNoOtherFieldPresent() {
        for (f in allFields) {
            val cfg = writeOnly(f)
            val alsoPresent = allFields.filter { it.label != f.label && it.has(cfg) }
            assertTrue(
                alsoPresent.isEmpty(),
                "${f.label}: writing it also marked ${alsoPresent.map { it.label }} present, " +
                    "so those share a predicate with it",
            )
        }
    }

    /**
     * Labels key the dialog's edit maps, so a duplicate silently cross-wires two settings'
     * edits. It also breaks the checks above, which identify fields by label.
     */
    @Test
    fun labelsAreUnique() {
        val dupes = allFields.groupBy { it.label }.filterValues { it.size > 1 }.keys
        assertTrue(dupes.isEmpty(), "duplicate expert-field labels: $dupes")
    }

    /**
     * A min of 0 is load-bearing on the three fields where 0 is a real setting rather than
     * "off" — no floor, no cap, never stream. A min of 1 would make them unreachable from
     * this client, and the daemon honours a present 0.
     */
    @Test
    fun fieldsWhoseZeroIsMeaningfulAllowZero() {
        val meaningfulZero = listOf("Horizon floor MB", "Max keypoint ops", "Merge streaming MB")
        for (label in meaningfulZero) {
            val f = allFields.firstOrNull { it.label == label }
            assertTrue(f is IntField, "$label: expected an IntField, found ${f?.let { it::class.simpleName }}")
            assertEquals(0, (f as IntField).min, "$label: 0 must be reachable, it is a real setting")
        }
    }

    @Test
    fun intFieldRangesAreSane() {
        for (f in allFields.filterIsInstance<IntField>()) {
            assertTrue(f.min <= f.max, "${f.label}: min ${f.min} exceeds max ${f.max}")
        }
    }

    // ---- helpers ----

    /** A config with exactly one field written, through that field's own setter. */
    private fun writeOnly(f: ExpertField): Config {
        val b = Config.newBuilder()
        when (f) {
            is IntField -> f.set(b, intProbe(f))
            is DoubleField -> f.set(b, DOUBLE_PROBE)
            is BoolField -> f.set(b, true)
        }
        return b.build()
    }

    /**
     * In range, and never 0 — a 0 would be indistinguishable from the proto3 default in the
     * getter check, which would let a mis-paired getter pass.
     */
    private fun intProbe(f: IntField): Int = f.max

    private companion object {
        const val DOUBLE_PROBE = 0.375
    }
}
