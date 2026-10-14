package com.star.desktop.data

import com.google.gson.Gson
import com.google.gson.reflect.TypeToken
import com.star.desktop.util.Log
import java.io.File

/**
 * Client-local UI preferences in `~/.star.userprefs.json` — the ONLY file the client serializes.
 *
 * The `recentlyOpenedSequencelist` schema (`{ "<path>": <epochSeconds> }`) is shared with the macOS
 * Swift app (`UserPreferences.swift`), so recent files are visible across both clients, and both open
 * an entry as a session's `config.json`. Every change re-reads the file first and writes back only the
 * keys it concerns, so keys this client does not know (the Swift app's) are kept as they are and a
 * change the other app made while this one was running is not undone.
 */
class LocalPreferences {
    private val prefsFile = File(System.getProperty("user.home"), ".star.userprefs.json")
    private val gson = Gson()

    /** Serialises the read-modify-write of [edit], and guards the in-memory copies below. */
    private val lock = Any()

    private val recent = linkedMapOf<String, Long>()

    /** macOS `skipRenderPromptAfterProcessing`: once set, processing starts without the render prompt. */
    @Volatile
    var skipRenderPromptAfterProcessing: Boolean = false
        private set

    /**
     * The language the user picked, or null to follow the system.
     *
     * Same key and same file as the macOS app's `UserPreferences.language`, so a machine with
     * both installed only has to be told once.
     */
    @Volatile
    var language: String? = null
        private set

    /**
     * How many reference horizons the user wants for a moving sequence, relative to what star
     * suggests for that sequence's length (macOS `UserPreferences.movingHorizonCountMultiplier`,
     * same key in the same file).
     *
     * A multiplier rather than a count, because the count that suits a sequence depends on how
     * long it is: `chosen / suggestedMovingHorizonCount(total)`, so 1.5 means "half again as many
     * as star suggests, whatever the length". null until the user first moves the stepper.
     */
    @Volatile
    var movingHorizonCountMultiplier: Double? = null
        private set

    // (declared before `init`, which fills it: a property initializer runs in declaration order, after any earlier init block)
    /** Every key the file had as of the last read or write, so preferences this class has no property for can still be read. */
    @Volatile
    private var snapshot: Map<String, Any?> = emptyMap()

    init {
        edit { map ->
            // What the macOS app does on load: forget recents whose file is gone (an unplugged drive, a
            // deleted project), rather than listing something that can only fail to open.
            val gone = recentOf(map).keys.filter { !File(it).exists() }
            if (gone.isNotEmpty()) map[RECENT_KEY] = recentOf(map).filterKeys { it !in gone }
        }
    }

    /**
     * A true/false preference the macOS app also stores (same key, same file): null when it has never been set, which the
     * macOS app reads as the preference's own default, so a caller says what that default is (`bool(k) ?: true`).
     */
    fun bool(key: String): Boolean? = snapshot[key] as? Boolean

    /** A text preference (this client's, or one the macOS app also stores under the same key); null when it has never been set. */
    fun string(key: String): String? = snapshot[key] as? String

    /** Set a text preference; null forgets it. */
    fun setString(key: String, value: String?) = edit { if (value == null) it.remove(key) else it[key] = value }

    /** A list of strings preference (this client's own, such as the outlier table's columns); null when it has never been set. */
    fun strings(key: String): List<String>? = (snapshot[key] as? List<*>)?.filterIsInstance<String>()

    /** Set a list of strings preference; null forgets it, returning it to its default. */
    fun setStrings(key: String, value: List<String>?) = edit { if (value == null) it.remove(key) else it[key] = value }

    /** Set a true/false preference; null forgets it, returning it to its default. */
    fun setBool(key: String, value: Boolean?) = edit { if (value == null) it.remove(key) else it[key] = value }

    /** macOS `showHorizonPainterInstructions`: whether the horizon painter shows its how-to over the frame when a startup flow opens it. */
    var showHorizonPainterInstructions: Boolean
        get() = bool("showHorizonPainterInstructions") ?: true
        set(value) = setBool("showHorizonPainterInstructions", value)

    /** macOS `showHorizonOnMainView`: whether the horizon line is drawn on the frame, the filmstrip and the grid. Off until turned on. */
    var showHorizonOnMainView: Boolean
        get() = bool("showHorizonOnMainView") ?: false
        set(value) = setBool("showHorizonOnMainView", value)

    fun setSkipRenderPrompt(value: Boolean) = edit { it["skipRenderPromptAfterProcessing"] = value }

    fun setLanguage(value: String?) = edit {
        // Written only when set: absent means "follow the system", and the Swift side decodes a
        // missing key to nil the same way.
        if (value == null) it.remove("language") else it["language"] = value
    }

    fun setMovingHorizonCountMultiplier(value: Double) = edit { it["movingHorizonCountMultiplier"] = value }

    /** The most recent sequence paths, most-recent first: at most [MAX_RECENT_SHOWN] of them. */
    val recentFiles: List<String>
        get() = synchronized(lock) {
            recent.entries.sortedByDescending { it.value }.take(MAX_RECENT_SHOWN).map { it.key }
        }

    /**
     * Record [path] as just opened: the session's config.json, which is what both clients open a recent
     * entry as. The list is not trimmed on write: the file is shared with the macOS app, which keeps
     * everything, and trimming here deleted its older entries.
     */
    fun addRecentFile(path: String) = edit { map ->
        map[RECENT_KEY] = recentOf(map) + (path to (System.currentTimeMillis() / 1000L).toDouble())
    }

    fun removeRecentFile(path: String) = edit { map -> map[RECENT_KEY] = recentOf(map) - path }

    private fun recentOf(map: Map<String, Any?>): Map<String, Any?> {
        @Suppress("UNCHECKED_CAST")
        return map[RECENT_KEY] as? Map<String, Any?> ?: emptyMap()
    }

    /** The file as it is now, empty when there is none or it cannot be read. */
    private fun read(): MutableMap<String, Any?> {
        if (!prefsFile.exists()) return linkedMapOf()
        return try {
            val type = object : TypeToken<MutableMap<String, Any?>>() {}.type
            gson.fromJson<MutableMap<String, Any?>>(prefsFile.readText(), type) ?: linkedMapOf()
        } catch (e: Exception) {
            Log.w("Prefs") { "failed to read $prefsFile: ${e.message}" }
            linkedMapOf()
        }
    }

    /**
     * Change some of the preferences. The file is read again just before the change and written straight
     * after, with only the keys [change] touches different: the macOS app writes the same file, and a
     * copy read at startup and written back whole would undo whatever it changed in the meantime. What
     * was written is then adopted as this instance's own copy.
     */
    private fun edit(change: (MutableMap<String, Any?>) -> Unit) = synchronized(lock) {
        val map = read()
        val before = gson.toJson(map)
        change(map)
        // Nothing to write, and no file to create just because the app was started.
        if (gson.toJson(map) != before) write(map)
        adopt(map)
    }

    private fun write(map: Map<String, Any?>) {
        try {
            prefsFile.writeText(gson.toJson(map))
        } catch (e: Exception) {
            Log.w("Prefs") { "failed to write $prefsFile: ${e.message}" }
        }
    }

    private fun adopt(map: Map<String, Any?>) {
        snapshot = map.toMap()
        recent.clear()
        recentOf(map).forEach { (k, v) -> recent[k] = (v as? Double)?.toLong() ?: 0L }
        skipRenderPromptAfterProcessing = map["skipRenderPromptAfterProcessing"] as? Boolean ?: false
        language = (map["language"] as? String)?.takeIf { it.isNotEmpty() }
        movingHorizonCountMultiplier =
            (map["movingHorizonCountMultiplier"] as? Double)?.takeIf { it > 0 && it.isFinite() }
    }

    private companion object {
        const val RECENT_KEY = "recentlyOpenedSequencelist"

        /** How many recent entries this client lists. The file itself keeps all of them. */
        const val MAX_RECENT_SHOWN = 20
    }
}
