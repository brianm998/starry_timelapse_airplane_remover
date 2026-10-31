package com.star.desktop.gherkin

import com.star.desktop.gherkin.generated.GeneratedParams
import com.star.desktop.gherkin.generated.StepAction

/** The data the generated `Features.kt` is written in. Mirrors gherkin/StarGherkin/Sources/StarGherkinKernel/Model.swift. */
enum class StepKeyword { GIVEN, WHEN, THEN, AND, BUT }

/** [args] are what the feature gave the step's inline arguments, in order (`I click "<id>"` with `"startup.horizon.no"` is `["startup.horizon.no"]`). */
data class Step(val keyword: StepKeyword, val action: StepAction, val args: List<String> = emptyList()) {
    /** The step's text with its inline arguments in: `"<id>"` becomes `"startup.horizon.no"`, `<n:int>` becomes `3`. */
    val text: String
        get() {
            var out = action.text
            val marker = Regex(""""<[a-z][A-Za-z0-9]*>"|<[a-z][A-Za-z0-9]*:int>""")
            for (arg in args) {
                val m = marker.find(out) ?: break
                out = out.replaceRange(m.range, if (m.value.startsWith("\"")) "\"$arg\"" else arg)
            }
            return out
        }

    /** The step as written in the feature file, e.g. `Given I open the sequence {sequence}` or `When I click "startup.horizon.no"`. */
    override fun toString(): String = "${keyword.name.lowercase().replaceFirstChar { it.uppercase() }} $text"
}

/** [id] is the feature file basename, which keys its per-feature params. */
data class Feature(val id: String, val name: String, val tags: List<String>, val scenario: String, val steps: List<Step>)

/** Placeholder values: env var `STAR_GHERKIN_<UPPER_NAME>`, then the feature's value, then the client's override, then the default. */
object Params {
    fun resolve(name: String, client: String, feature: String? = null, env: Map<String, String> = System.getenv()): String? {
        val envName = "STAR_GHERKIN_" + name.uppercase().map { if (it.isLetterOrDigit()) it else '_' }.joinToString("")
        env[envName]?.takeIf { it.isNotEmpty() }?.let { return it }
        feature?.let { GeneratedParams.features[it]?.get(name) }?.let { return it }
        GeneratedParams.overrides[client]?.get(name)?.let { return it }
        return GeneratedParams.defaults[name]
    }
}
