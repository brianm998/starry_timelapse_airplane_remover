package com.star.desktop.data

import com.google.gson.Gson
import com.google.gson.reflect.TypeToken
import com.star.desktop.domain.FrameRatePref
import com.star.desktop.domain.GpuToggle
import com.star.desktop.util.Log
import java.io.File
import java.nio.file.AtomicMoveNotSupportedException
import java.nio.file.Files
import java.nio.file.StandardCopyOption

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

    /** Set when the file exists but did not parse: [edit] then keeps its changes in memory and leaves the file alone. */
    @Volatile
    private var loadFailed = false

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

    /** The stored value under [key] as the file holds it, for a preference whose shape is not one of the simple ones above (the frame rate's). */
    fun raw(key: String): Any? = snapshot[key]

    /** Store [value] as it is, or forget [key] for null. */
    fun setRaw(key: String, value: Any?) = edit { if (value == null) it.remove(key) else it[key] = value }

    /** Set a true/false preference; null forgets it, returning it to its default. */
    fun setBool(key: String, value: Boolean?) = edit { if (value == null) it.remove(key) else it[key] = value }

    /** macOS `showHorizonPainterInstructions`: whether the horizon painter shows its how-to over the frame when a startup flow opens it. */
    var showHorizonPainterInstructions: Boolean
        get() = bool("showHorizonPainterInstructions") ?: true
        set(value) = setBool("showHorizonPainterInstructions", value)

    /**
     * macOS `hiddenHorizonLineKinds`: the kinds of horizon line (initial, merged, consensus, reference) the user has switched
     * off; empty draws every kind a frame has.  The hidden ones rather than the shown ones, so a kind added later is drawn.
     */
    var hiddenHorizonLineKinds: List<String>
        get() = strings("hiddenHorizonLineKinds") ?: emptyList()
        set(value) = setStrings("hiddenHorizonLineKinds", value.distinct().sorted())

    /** macOS `showHorizonOnMainView`: whether the horizon line is drawn on the frame, the filmstrip and the grid. Off until turned on. */
    var showHorizonOnMainView: Boolean
        get() = bool("showHorizonOnMainView") ?: false
        set(value) = setBool("showHorizonOnMainView", value)

    /**
     * macOS `showProcessingWindow`: whether starting a run puts the processing screen up over the window. On unless the user has turned it off
     * (the Status button in the left panel brings it back for a run in progress either way).
     */
    var showProcessingWindow: Boolean
        get() = bool("showProcessingWindow") ?: true
        set(value) = setBool("showProcessingWindow", value)

    /**
     * macOS `showAlignmentInProcessingWindow`: whether the processing screen draws its alignment charts. Off until turned on; kept here
     * and not in the screen's own state, which is rebuilt every time the screen is dismissed and brought back.
     */
    var showAlignmentInProcessingWindow: Boolean
        get() = bool("showAlignmentInProcessingWindow") ?: false
        set(value) = setBool("showAlignmentInProcessingWindow", value)

    /**
     * What the user last chose in the Render Video dialog, under the keys the macOS app uses (`frameRate`, `codec`, `encoder`, `pixelFormat`,
     * `muxer`), so a new render starts from it in either app. Null where nothing has been chosen.
     */
    var videoFrameRate: Double?
        get() = FrameRatePref.fromPref(raw("frameRate"))
        set(value) = setRaw("frameRate", value?.let { FrameRatePref.toPref(it) })
    var videoCodec: String?
        get() = string("codec")?.takeIf { it.isNotEmpty() }
        set(value) = setString("codec", value)
    var videoEncoder: String?
        get() = string("encoder")?.takeIf { it.isNotEmpty() }
        set(value) = setString("encoder", value)
    var videoPixelFormat: String?
        get() = string("pixelFormat")?.takeIf { it.isNotEmpty() }
        set(value) = setString("pixelFormat", value)
    var videoMuxer: String?
        get() = string("muxer")?.takeIf { it.isNotEmpty() }
        set(value) = setString("muxer", value)

    /**
     * One of the three GPU toggles as the user last set it (macOS `useGPUForMerge` / `useGPUForSIFT` / `useGPUForAKAZE`, same keys, same file),
     * or null when they have never chosen, which leaves a sequence's own config in charge.
     */
    fun gpu(toggle: GpuToggle): Boolean? = bool(toggle.key)

    fun setGpu(toggle: GpuToggle, value: Boolean) = setBool(toggle.key, value)

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

    /** The file as it is now: empty when there is none, null when there is one that does not parse. */
    private fun read(): MutableMap<String, Any?>? {
        if (!prefsFile.exists()) return linkedMapOf()
        return try {
            val text = prefsFile.readText()
            // Nothing in a blank file to protect, and nothing to parse.
            if (text.isBlank()) return linkedMapOf()
            val type = object : TypeToken<MutableMap<String, Any?>>() {}.type
            gson.fromJson<MutableMap<String, Any?>>(text, type) ?: linkedMapOf()
        } catch (e: Exception) {
            Log.w("Prefs") { "failed to read $prefsFile: ${e.message}" }
            null
        }
    }

    /** Keep a copy of the unreadable file for the user, once, and stop writing to it for the rest of this run. */
    private fun markLoadFailed() {
        if (!loadFailed) Log.w("Prefs") { "not saving preferences: $prefsFile could not be read and would be overwritten" }
        loadFailed = true
        val copy = File(prefsFile.path + ".undecodable")
        if (prefsFile.exists() && !copy.exists()) {
            try {
                Files.copy(prefsFile.toPath(), copy.toPath())
            } catch (e: Exception) {
                Log.w("Prefs") { "could not keep a copy of $prefsFile: ${e.message}" }
            }
        }
    }

    /**
     * Change some of the preferences. The file is read again just before the change and written straight
     * after, with only the keys [change] touches different: the macOS app writes the same file, and a
     * copy read at startup and written back whole would undo whatever it changed in the meantime. What
     * was written is then adopted as this instance's own copy.
     *
     * When the file cannot be parsed the change is made to this instance's copy only, so it still holds for
     * the session, and the file is left as it is.
     */
    private fun edit(change: (MutableMap<String, Any?>) -> Unit) = synchronized(lock) {
        val onDisk = if (loadFailed) null else read()
        if (onDisk == null && !loadFailed) markLoadFailed()
        val map = onDisk ?: LinkedHashMap(snapshot)
        val before = gson.toJson(map)
        change(map)
        // Nothing to write, and no file to create just because the app was started.
        if (!loadFailed && gson.toJson(map) != before) write(map)
        adopt(map)
    }

    /** Written beside the file and renamed over it: removing it first, or writing it in place, leaves a window with a missing or empty file. */
    private fun write(map: Map<String, Any?>) {
        val temp = File(prefsFile.parentFile, "${prefsFile.name}.tmp")
        try {
            temp.writeText(gson.toJson(map))
            try {
                Files.move(temp.toPath(), prefsFile.toPath(), StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING)
            } catch (e: AtomicMoveNotSupportedException) {
                Files.move(temp.toPath(), prefsFile.toPath(), StandardCopyOption.REPLACE_EXISTING)
            }
        } catch (e: Exception) {
            Log.w("Prefs") { "failed to write $prefsFile: ${e.message}" }
            temp.delete()
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
