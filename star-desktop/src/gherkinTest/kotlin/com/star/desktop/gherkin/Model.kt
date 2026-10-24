package com.star.desktop.gherkin

import com.star.desktop.gherkin.generated.GeneratedParams
import com.star.desktop.gherkin.generated.StepAction

/** The data the generated `Features.kt` is written in. Mirrors gherkin/StarGherkin/Sources/StarGherkinKernel/Model.swift. */
enum class StepKeyword { GIVEN, WHEN, THEN, AND, BUT }

data class Step(val keyword: StepKeyword, val action: StepAction) {
    /** The step as written in the feature file, e.g. `Given I open the sequence {sequence}`. */
    override fun toString(): String = "${keyword.name.lowercase().replaceFirstChar { it.uppercase() }} ${action.text}"
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
