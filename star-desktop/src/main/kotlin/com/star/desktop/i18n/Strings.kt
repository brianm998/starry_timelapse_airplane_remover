package com.star.desktop.i18n

import androidx.compose.runtime.mutableStateOf
import com.google.gson.Gson
import com.google.gson.reflect.TypeToken
import com.star.desktop.util.Log
import java.util.Locale

/**
 * Every user-visible string in the client, in the language the user reads.
 *
 * ## One catalogue, both clients
 *
 * The tables are the *same files* the Swift side uses — `StarCore/…/Resources/Localizations/`,
 * copied into this jar at `/i18n/` by `processResources`. The macOS app and this client are the
 * same application on two toolchains, and their strings overlap almost entirely; a second
 * catalogue would have meant every new label translated twice and drifting immediately.
 *
 * Placeholders are `{0}`, `{1}` — positional, so a translator can reorder them, and identical to
 * what `StarLocalization` substitutes on the Swift side.
 *
 * ## Recomposition
 *
 * [currentCode] is backed by a Compose `mutableStateOf`, and [localized] reads it on every
 * lookup. That read is what makes a language change repaint the UI: any composable that shows a
 * string has, by definition, called through here, so Compose's snapshot system already knows to
 * invalidate it. No `key()` wrapper and nothing for a view to remember to observe.
 */
object Strings {

    private const val RESOURCE_DIR = "/i18n"
    const val SOURCE_LANGUAGE = "en"

    private val gson = Gson()
    private val tables = HashMap<String, Map<String, String>>()
    private val reportedMissing = HashSet<String>()

    /** Loaded once; the manifest is small and every language picker needs all of it. */
    val languages: List<StarLanguage> = loadManifest()

    private val overrideState = mutableStateOf<String?>(null)
    private val codeState = mutableStateOf(resolve(null))

    /**
     * The language being displayed. Reading this from a composable subscribes it to changes.
     */
    val currentCode: String get() = codeState.value

    val current: StarLanguage
        get() = languages.firstOrNull { it.code == currentCode }
            ?: StarLanguage(SOURCE_LANGUAGE, "English", "English", false)

    /** The user's explicit pick, or null when following the system. */
    val languageOverride: String? get() = overrideState.value

    val isFollowingSystem: Boolean get() = overrideState.value == null

    /** Switch languages. `null` goes back to following the machine. */
    fun setOverride(code: String?) {
        overrideState.value = code
        codeState.value = resolve(code)
    }

    /** The localized string for [key], falling back to English and then to the key itself. */
    fun get(key: String): String {
        val code = codeState.value                     // tracked read — see the class comment
        table(code)[key]?.let { return it }

        if (code != SOURCE_LANGUAGE) {
            table(SOURCE_LANGUAGE)[key]?.let {
                reportMissing(key, code, fellBackToEnglish = true)
                return it
            }
        }
        reportMissing(key, code, fellBackToEnglish = false)
        return key
    }

    /** [get] with `{0}`, `{1}`, … replaced by [args]. */
    fun get(key: String, vararg args: Any?): String = substitute(get(key), args)

    internal fun substitute(format: String, args: Array<out Any?>): String {
        if (args.isEmpty()) return format
        var result = format
        // Highest index first: replacing {1} before {10} would corrupt {10} into "<arg1>0".
        for (i in args.indices.reversed()) {
            result = result.replace("{$i}", args[i].toString())
        }
        return result
    }

    private fun table(code: String): Map<String, String> = tables.getOrPut(code) {
        val path = "$RESOURCE_DIR/$code.json"
        val stream = Strings::class.java.getResourceAsStream(path)
        if (stream == null) {
            Log.w("i18n") { "no localization table at $path" }
            return@getOrPut emptyMap()
        }
        try {
            stream.reader(Charsets.UTF_8).use { reader ->
                val type = object : TypeToken<Map<String, String>>() {}.type
                gson.fromJson<Map<String, String>>(reader, type) ?: emptyMap()
            }
        } catch (e: Exception) {
            Log.w("i18n") { "could not read $path: ${e.message}" }
            emptyMap()
        }
    }

    private fun loadManifest(): List<StarLanguage> {
        val fallback = listOf(StarLanguage(SOURCE_LANGUAGE, "English", "English", false))
        val stream = Strings::class.java.getResourceAsStream("$RESOURCE_DIR/languages.json")
            ?: run {
                Log.w("i18n") { "localization manifest missing — English only" }
                return fallback
            }
        return try {
            stream.reader(Charsets.UTF_8).use { reader ->
                gson.fromJson(reader, StarLanguageManifest::class.java)?.languages ?: fallback
            }
        } catch (e: Exception) {
            Log.w("i18n") { "could not read the localization manifest: ${e.message}" }
            fallback
        }
    }

    private fun reportMissing(key: String, code: String, fellBackToEnglish: Boolean) {
        // Once per key: a missing string in a composable would otherwise log on every frame.
        if (!reportedMissing.add(key)) return
        if (fellBackToEnglish) {
            Log.d("i18n") { "no '$code' translation for '$key' — showing English" }
        } else {
            Log.w("i18n") { "no localized string for '$key' — showing the key" }
        }
    }

    // ---- choosing a language -------------------------------------------------------------

    /** Explicit pick, then `STAR_LANG`, then the JVM's default locale, then English. */
    internal fun resolve(override: String?): String {
        val shipped = languages.map { it.code }
        if (!override.isNullOrEmpty()) bestMatch(override, shipped)?.let { return it }

        System.getenv("STAR_LANG")?.takeIf { it.isNotEmpty() }
            ?.let { bestMatch(it, shipped)?.let { m -> return m } }

        val default = Locale.getDefault()
        // toLanguageTag() gives "pt-BR" / "zh-Hans-CN", which is what the tables are named by.
        bestMatch(default.toLanguageTag(), shipped)?.let { return it }
        bestMatch(default.language, shipped)?.let { return it }

        return SOURCE_LANGUAGE
    }

    /**
     * Match a requested BCP-47 tag against what star ships: whole tag, then progressively
     * shorter prefixes, then any shipped language with the same base. The last pass is what
     * sends `pt-PT` to `pt-BR` and `zh-Hant-TW` to `zh-Hans`. Mirrors
     * `StarLocalization.bestMatch` on the Swift side — the two must agree, or the same machine
     * would open the two clients in different languages.
     */
    internal fun bestMatch(requested: String, shipped: List<String>): String? {
        val wanted = requested.replace('_', '-')
        if (wanted.isEmpty()) return null

        fun find(tag: String) = shipped.firstOrNull { it.equals(tag, ignoreCase = true) }

        find(wanted)?.let { return it }

        val parts = wanted.split('-').toMutableList()
        while (parts.size > 1) {
            parts.removeAt(parts.size - 1)
            find(parts.joinToString("-"))?.let { return it }
        }

        val base = parts.firstOrNull() ?: wanted
        return shipped.firstOrNull { it.substringBefore('-').equals(base, ignoreCase = true) }
    }
}

/**
 * The localized string for [key], with any `{0}`, `{1}` … replaced.
 *
 * Deliberately a short top-level function, and deliberately the same name as the Swift one, so
 * the two clients' view code reads the same and a string can be moved between them unchanged.
 */
fun localized(key: String, vararg args: Any?): String =
    if (args.isEmpty()) Strings.get(key) else Strings.get(key, *args)
