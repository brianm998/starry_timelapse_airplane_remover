package com.star.desktop.i18n

/**
 * One language star ships translations for.
 *
 * Field names match `StarLanguage` in StarCore — this is deserialized straight out of the same
 * `languages.json`, so they have to.
 */
data class StarLanguage(
    /** BCP-47 tag, and the basename of this language's table: `pt-BR` ⇒ `pt-BR.json`. */
    val code: String,
    /**
     * The language's name in that language. What a picker must show: someone who has landed in
     * a language they cannot read finds their way out by recognising their own, and "Japanese"
     * is no help when the UI is already in Japanese.
     */
    val nativeName: String,
    /** The language's name in English, for logs and bug reports. */
    val englishName: String,
    /** Arabic and Urdu. Read by anything that can flip layout direction. */
    val rightToLeft: Boolean,
)

/** The shape of `languages.json`. */
internal data class StarLanguageManifest(
    val sourceLanguage: String,
    val languages: List<StarLanguage>,
)
