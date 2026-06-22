package com.star.data

import com.google.gson.Gson
import com.google.gson.reflect.TypeToken
import java.io.File

/**
 * Client-local UI preferences stored in ~/.star.userprefs.json.
 *
 * The schema is shared with the macOS Swift app (UserPreferences.swift) so that
 * recent-files and basic preferences are visible across both clients on the same machine.
 * This is the ONLY file the Kotlin client serializes itself.
 *
 * Schema:
 *   { "recentlyOpenedSequencelist": { "<path>": <epochSeconds: Long>, ... }, ... }
 */
class LocalPreferences {

    private val prefsFile = File(System.getProperty("user.home"), ".star.userprefs.json")
    private val gson = Gson()

    data class Prefs(
        val recentlyOpenedSequencelist: MutableMap<String, Long> = mutableMapOf(),
        val windowWidth: Int = 1280,
        val windowHeight: Int = 800,
    )

    private var _prefs: Prefs = load()

    val recentFiles: List<Pair<String, Long>>
        get() = _prefs.recentlyOpenedSequencelist.entries
            .sortedByDescending { it.value }
            .map { it.key to it.value }

    fun addRecentFile(path: String) {
        _prefs.recentlyOpenedSequencelist[path] = System.currentTimeMillis() / 1000L
        // Keep at most 20 recent entries.
        if (_prefs.recentlyOpenedSequencelist.size > 20) {
            val oldest = _prefs.recentlyOpenedSequencelist.entries
                .sortedBy { it.value }
                .take(_prefs.recentlyOpenedSequencelist.size - 20)
            oldest.forEach { _prefs.recentlyOpenedSequencelist.remove(it.key) }
        }
        save()
    }

    fun removeRecentFile(path: String) {
        _prefs.recentlyOpenedSequencelist.remove(path)
        save()
    }

    var windowWidth: Int
        get() = _prefs.windowWidth
        set(v) { _prefs = _prefs.copy(windowWidth = v); save() }

    var windowHeight: Int
        get() = _prefs.windowHeight
        set(v) { _prefs = _prefs.copy(windowHeight = v); save() }

    private fun load(): Prefs {
        if (!prefsFile.exists()) return Prefs()
        return try {
            // The JSON may have extra fields from the Swift app; Gson ignores unknown fields.
            val raw = prefsFile.readText()
            val type = object : TypeToken<Map<String, Any>>() {}.type
            val map: Map<String, Any> = gson.fromJson(raw, type) ?: return Prefs()

            @Suppress("UNCHECKED_CAST")
            val recentRaw = map["recentlyOpenedSequencelist"] as? Map<String, Double> ?: emptyMap()
            val recent = recentRaw.mapValues { it.value.toLong() }.toMutableMap()
            Prefs(recentlyOpenedSequencelist = recent)
        } catch (_: Exception) {
            Prefs()
        }
    }

    private fun save() {
        try {
            val map = mapOf(
                "recentlyOpenedSequencelist" to _prefs.recentlyOpenedSequencelist,
                "windowWidth" to _prefs.windowWidth,
                "windowHeight" to _prefs.windowHeight,
            )
            prefsFile.writeText(gson.toJson(map))
        } catch (_: Exception) { /* best-effort */ }
    }
}
