package com.star.desktop.domain

import java.io.File

/**
 * Where a run's working files (`star_temp_<name>`), its output and, for a video, the extracted frames go, and whether the volume has room for
 * them. The daemon already puts all three under the config's `output_path`, so choosing a location is choosing that folder; this is only the
 * arithmetic the dialogs show before the user agrees to it.
 */
object WorkingLocation {
    /**
     * Peak disk use over a run as a multiple of the input sequence's size: the output plus the working files, which coexist while it runs.
     * Measured on a real sequence (4.13x), rounded down as `DiskSpaceCheck.peakToInputRatio` in StarCore does, which this mirrors.
     */
    const val PEAK_TO_INPUT_RATIO = 4.0

    private val IMAGE_EXTS = setOf("jpg", "jpeg", "tif", "tiff", "png")

    /** What the run needs on top of [inputBytes] already being on disk (a sequence's own files are there before it starts). */
    fun runBytes(inputBytes: Long): Long = Math.round(inputBytes * PEAK_TO_INPUT_RATIO)

    /** Total size of the image files directly in [dir], which is what the output and the working files are sized by. */
    fun sequenceInputBytes(dir: File): Long =
        dir.listFiles()?.filter { it.isFile && it.extension.lowercase() in IMAGE_EXTS }?.sumOf { it.length() } ?: 0L

    /**
     * Free bytes on the volume that holds [path], or null when that cannot be told. The folder usually does not exist yet, and asking about a
     * path that is not there answers 0, so this asks the nearest ancestor that is.
     */
    fun freeBytes(path: String): Long? {
        var f: File? = File(path).absoluteFile
        while (f != null && !f.exists()) f = f.parentFile
        val free = f?.usableSpace ?: return null
        return if (free > 0 || f.totalSpace > 0) free else null
    }

    /**
     * What the dialogs show as available: what the daemon says, since it counts as StarCore's own disk check does (on a Mac, including what the
     * system would purge to make room: the JVM does not, and the desktop reported a shortage the gui did not, S9), and this machine's
     * [freeBytes] when the daemon cannot say, is too old to be asked, or is not there.
     */
    suspend fun freeBytesAsTheDaemonCountsThem(path: String, ask: suspend (String) -> Long?): Long? =
        (try { ask(path) } catch (e: kotlinx.coroutines.CancellationException) { throw e } catch (e: Exception) { null }) ?: freeBytes(path)

    /** The folder the frames, output and working files go under unless the user chooses another: beside the source, as before. */
    fun defaultFolder(source: String): String = File(source).absoluteFile.parent ?: source
}
